<#
.SYNOPSIS
    一键在外机部署 SSH client 配置,使其能通过 VPS + FRP 连接到本机 Win11。

.DESCRIPTION
    交互式脚本:
      1. 检查/安装 OpenSSH Client
      2. 在 ~/.ssh/ 下生成或导入私钥
      3. 写 ~/.ssh/config(含 FRP VPS 地址 + 用户名)
      4. 创建 PowerShell alias / 桌面快捷方式

    不含任何硬编码的私钥 / 密码。

.PARAMETER VpsHost
    VPS 公网 IP 或域名(FRPS 所在)
.PARAMETER SshPort
    FRPS 上 SSH 转发的端口(默认 6000)
.PARAMETER LocalUser
    本机 Win11 的 SSH 用户名(连过去登录用的)
.PARAMETER KeyPath
    私钥文件路径(脚本不生成,必须由你从本机手动导出后放在外机)

.EXAMPLE
    .\deploy-windows.ps1
    # 走交互模式,逐项提示

.EXAMPLE
    .\deploy-windows.ps1 -VpsHost 8.163.106.31 -SshPort 6000 -LocalUser WuKong -KeyPath C:\Users\Other\.ssh\id_ed25519
#>

[CmdletBinding()]
param(
    [string]$VpsHost,
    [int]$SshPort = 6000,
    [string]$LocalUser,
    [string]$KeyPath
)

$ErrorActionPreference = 'Stop'
$cfg = "$env:USERPROFILE\.ssh\config"
$cfgDir = "$env:USERPROFILE\.ssh"

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
if (-not $KeyPath) {
    $KeyPath = Read-Host "私钥文件完整路径(放在外机的)"
    if (-not (Test-Path $KeyPath)) {
        Write-Error "私钥不存在: $KeyPath`n请先把本机的 id_ed25519 通过安全渠道拷过来。"
    }
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
Write-Step "2/5" "准备 $cfgDir"
if (-not (Test-Path $cfgDir)) {
    New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null
    Write-Host "已创建 $cfgDir"
}

# ---------- 3. 校验私钥 ----------
Write-Step "3/5" "校验私钥文件"
$privFull = (Resolve-Path $KeyPath).Path
Write-Host "私钥路径: $privFull"
# 用 ssh-keygen -y 测一下能不能导出公钥(空 passphrase 直接成功,有 passphrase 会让你输)
$tmpPub = Join-Path $env:TEMP "verify_pub.txt"
$proc = Start-Process -FilePath 'ssh-keygen' -ArgumentList @('-y','-f',$privFull,'-P','""') -NoNewWindow -Wait -RedirectStandardOutput $tmpPub -RedirectStandardError "$tmpPub.err" -PassThru
if ($proc.ExitCode -ne 0) {
    Write-Warning "私钥校验失败(可能是有 passphrase 的)。脚本继续,但首次连接时 ssh 会提示输入 passphrase。"
} else {
    Write-Host "私钥可解析,公钥指纹:"
    Get-Content $tmpPub
}
Remove-Item $tmpPub,$tmpPub.err -ErrorAction SilentlyContinue

# ---------- 4. 写 ~/.ssh/config ----------
Write-Step "4/5" "写入 $cfg"
$block = @"

# ===== ssh-deploy: 通过 FRP 连回本机 Win11 =====
Host wukong-pc
    HostName $VpsHost
    Port $SshPort
    User $LocalUser
    IdentityFile $privFull
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
"@
# 如果 cfg 不存在就建
if (-not (Test-Path $cfg)) {
    New-Item -ItemType File -Path $cfg -Force | Out-Null
}
Add-Content -Path $cfg -Value $block -Encoding UTF8
Write-Host "config 已追加:"

# ---------- 5. 创建便捷 alias ----------
Write-Step "5/5" "创建 PowerShell profile alias"
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
$aliasLine = "function wukong { ssh wukong-pc }`nSet-Alias -Name wpc -Value wukong`n"
if (-not (Select-String -Path $PROFILE -Pattern 'function wukong' -SimpleMatch -Quiet)) {
    Add-Content -Path $PROFILE -Value "`n# ssh-deploy alias`n$aliasLine" -Encoding UTF8
    Write-Host "alias `wpc` 已写入 $PROFILE"
} else {
    Write-Host "alias 已存在,跳过"
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "部署完成!" -ForegroundColor Green
Write-Host "  重启 PowerShell 后输: ssh wukong-pc  或  wpc" -ForegroundColor Green
Write-Host "  首次会确认 host key,输 yes 后即可登录。" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green