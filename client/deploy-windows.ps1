<#
.SYNOPSIS
    一键在外机部署 SSH client 配置,使其能通过 VPS + FRP 连接到本机 Win11。

.DESCRIPTION
    交互式脚本:
      1. 检查/安装 OpenSSH Client
      2. 提示直接粘贴私钥内容(无需先存文件),写到 ~/.ssh/id_ed25519
      3. 写 ~/.ssh/config(含 FRP VPS 地址 + 用户名)
      4. 创建 PowerShell profile alias

    不含任何硬编码的私钥 / 密码。私钥通过终端粘贴,落地到本地 ~/.ssh/。

.PARAMETER VpsHost
    VPS 公网 IP 或域名(FRPS 所在)
.PARAMETER SshPort
    FRP 上 SSH 转发的端口(默认 6000)
.PARAMETER LocalUser
    本机 Win11 的 SSH 用户名(连过去登录用的)
.PARAMETER KeyName
    私钥写入文件名(默认 id_ed25519)

.EXAMPLE
    .\deploy-windows.ps1
    # 提示输入 VPS / 用户名 / 私钥(粘贴多行内容,以单独一行的 END 结束)

.EXAMPLE
    .\deploy-windows.ps1 -VpsHost 8.163.106.31 -LocalUser WuKong
#>

[CmdletBinding()]
param(
    [string]$VpsHost,
    [int]$SshPort = 6000,
    [string]$LocalUser,
    [string]$KeyName = 'id_ed25519'
)

$ErrorActionPreference = 'Stop'
$sshDir = "$env:USERPROFILE\.ssh"
$cfg = "$sshDir\config"
$keyPath = Join-Path $sshDir $KeyName

function Write-Step($n, $msg) {
    Write-Host ""
    Write-Host "[$n] $msg" -ForegroundColor Cyan
}

# ---------- 0. 交互式收集缺失参数 ----------
if (-not $VpsHost) {
    $VpsHost = Read-Host "VPS 公网 IP 或域名(FRPS 所在)"
}
if (-not $LocalUser) {
    $LocalUser = Read-Host "本机 Win11 的 SSH 用户名"
}

# ---------- 1. 检查 OpenSSH Client ----------
Write-Step "1/5" "检查 OpenSSH Client..."
$clientCapable = (Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction SilentlyContinue) | Where-Object State -eq "Installed"
if (-not $clientCapable) {
    Write-Host "OpenSSH Client 未安装,正在安装..."
    Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0"
} else {
    Write-Host "OpenSSH Client 已安装。"
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Error "安装后仍找不到 ssh 命令,需要重启 PowerShell 或检查 PATH"
}

# ---------- 2. 准备 ~/.ssh 目录 ----------
Write-Step "2/5" "准备 $sshDir"
if (-not (Test-Path $sshDir)) {
    New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
}

# ---------- 3. 粘贴 base64 编码的私钥(单行,以回车结束) ----------
Write-Step "3/5" "粘贴私钥的 base64 编码(单行,回车结束)"
Write-Host "  主控端生成:  base64 ~/.ssh/id_ed25519  (或 Win PS: [Convert]::ToBase64String([IO.File]::ReadAllBytes('id_ed25519')))"
Write-Host "  把输出的一长串字符粘贴进来,按回车即可。"
Write-Host ""
Write-Host "  > " -NoNewline

# 一次性读一行(从 console,不被 iex 劫持)
$line = [Console]::In.ReadLine()
# 去掉所有空白 / CR
$keyB64 = $line -replace '\s', ''

# 兼容性:用户可能分多行粘贴,继续读直到空白行
while ($true) {
    Write-Host "  > " -NoNewline
    $extra = [Console]::In.ReadLine()
    if ([string]::IsNullOrWhiteSpace($extra)) { break }
    $keyB64 += ($extra -replace '\s', '')
}

# base64 解码
try {
    $keyBytes = [Convert]::FromBase64String($keyB64)
    $keyContent = [System.Text.Encoding]::UTF8.GetString($keyBytes)
} catch {
    Write-Error "base64 解码失败: $($_.Exception.Message)。检查输入是否完整、是否带 = padding。"
}

# 校验:必须含 BEGIN/END
if ($keyContent -notmatch '-----BEGIN .* PRIVATE KEY-----') {
    Write-Error "解码后没看到 BEGIN 标记。base64 输入有误或被截断。"
}
if ($keyContent -notmatch '-----END .* PRIVATE KEY-----') {
    Write-Error "解码后没看到 END 标记。"
}

[System.IO.File]::WriteAllText($keyPath, $keyContent + "`n", [System.Text.Encoding]::UTF8)
icacls $keyPath /inheritance:r /grant:r "${env:USERNAME}:(R)" | Out-Null
Write-Host "已写 $keyPath"

# ---------- 4. 校验私钥 + 写 ~/.ssh/config ----------
Write-Step "4/5" "校验私钥 + 写 ssh config"
$tmpPub = Join-Path $env:TEMP "verify_pub.txt"
$proc = Start-Process -FilePath 'ssh-keygen' -ArgumentList @('-y','-f',$keyPath,'-P','""') `
    -NoNewWindow -Wait -RedirectStandardOutput $tmpPub -RedirectStandardError "$tmpPub.err" -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Warning "私钥校验失败(可能带 passphrase)。首次连接 ssh 会要求输入。"
} else {
    Write-Host "私钥 OK,公钥指纹:"
    Get-Content $tmpPub
}
Remove-Item $tmpPub,"$tmpPub.err" -ErrorAction SilentlyContinue

$block = @"

# ===== ssh-deploy: 通过 FRP 连回本机 Win11 =====
Host wukong-pc
    HostName $VpsHost
    Port $SshPort
    User $LocalUser
    IdentityFile $keyPath
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
"@
if (-not (Test-Path $cfg)) { New-Item -ItemType File -Path $cfg -Force | Out-Null }
Add-Content -Path $cfg -Value $block -Encoding UTF8

# ---------- 5. 创建 PowerShell alias ----------
Write-Step "5/5" "创建 PowerShell alias"
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
$aliasLine = "function wukong { ssh wukong-pc }`nSet-Alias -Name wpc -Value wukong`n"
if (-not (Select-String -Path $PROFILE -Pattern 'function wukong' -SimpleMatch -Quiet)) {
    Add-Content -Path $PROFILE -Value "`n# ssh-deploy alias`n$aliasLine" -Encoding UTF8
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "部署完成!" -ForegroundColor Green
Write-Host "  重启 PowerShell 后输: ssh wukong-pc  或  wpc" -ForegroundColor Green
Write-Host "  首次会确认 host key,输 yes 后即可登录。" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green