<#
.SYNOPSIS
    一键在外机部署 SSH client,使其能通过 VPS + FRP 连接到本机 Win11。

.DESCRIPTION
    交互式脚本(密码认证,不需要私钥):
      1. 检查/安装 OpenSSH Client
      2. 写 ~/.ssh/config(FRP VPS 地址 + 用户名)
      3. 创建 PowerShell profile alias

    主机侧要求:本机 sshd 已开 PasswordAuthentication yes。
    外机连时每次输 Win11 账号密码。

.PARAMETER VpsHost
    VPS 公网 IP 或域名(FRPS 所在)
.PARAMETER SshPort
    FRP 上 SSH 转发的端口(默认 6000)
.PARAMETER LocalUser
    本机 Win11 的账号用户名

.EXAMPLE
    .\deploy-windows.ps1
    # 提示输入 VPS / 用户名

.EXAMPLE
    .\deploy-windows.ps1 -VpsHost 8.163.106.31 -LocalUser WuKong
#>

[CmdletBinding()]
param(
    [string]$VpsHost,
    [int]$SshPort = 0,  # 0 = 未传,后续交互问
    [string]$LocalUser
)

$ErrorActionPreference = 'Stop'
$sshDir = "$env:USERPROFILE\.ssh"
$cfg = "$sshDir\config"

$DEFAULT_VPS = '8.163.106.31'
$DEFAULT_PORT = 6000
$DEFAULT_USER = 'WuKong'

function Write-Step($n, $msg) {
    Write-Host ""
    Write-Host "[$n] $msg" -ForegroundColor Cyan
}

# ---------- 0. 交互式收集 ----------
if (-not $VpsHost) {
    $VpsHost = Read-Host "VPS 公网 IP 或域名(FRPS 所在) [$DEFAULT_VPS]"
    if (-not $VpsHost) { $VpsHost = $DEFAULT_VPS }
}

if (-not $LocalUser) {
    $LocalUser = Read-Host "本机 Win11 的账号用户名 [$DEFAULT_USER]"
    if (-not $LocalUser) { $LocalUser = $DEFAULT_USER }
}
if (-not $LocalUser) {
    Write-Error "用户名不能为空,脚本退出"
}

if ($SshPort -le 0) {
    $portInput = Read-Host "FRP SSH 转发端口 [$DEFAULT_PORT]"
    if ($portInput) { $SshPort = [int]$portInput } else { $SshPort = $DEFAULT_PORT }
}

# ---------- 1. OpenSSH Client ----------
Write-Step "1/3" "检查 OpenSSH Client..."
$hasCapability = $true
try {
    $cap = (Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction SilentlyContinue) | Where-Object State -eq "Installed"
    if (-not $cap) {
        Write-Host "正在安装 OpenSSH Client..."
        Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" -ErrorAction Stop | Out-Null
    } else {
        Write-Host "OpenSSH Client 已安装。"
    }
} catch {
    Write-Host "⚠️  Get-WindowsCapability 失败:$_" -ForegroundColor Yellow
    Write-Host "    (常见于 Win 镜像裁剪 / AppX 注册表损坏) fallback 到二进制检查" -ForegroundColor Yellow
    $hasCapability = $false
}

if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    # fallback:从 WinSxS 直接拷(同 host 脚本逻辑)
    $winsxsDirs = Get-ChildItem "$env:SystemRoot\WinSxS\amd64_openssh-client-components-onecore_*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Name -split '_')[3] } -Descending
    if ($winsxsDirs) {
        $src = $winsxsDirs[0].FullName
        $dest = "$env:SystemRoot\System32\OpenSSH"
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        # medium-IL 可写 System32\OpenSSH(不像 host 拷 Server 那样被拒)
        Copy-Item -Path "$src\*" -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "✅ 从 WinSxS 拷 OpenSSH Client 到 $dest" -ForegroundColor Green
    } else {
        Write-Error "找不到 ssh.exe,也没 WinSxS 源。手动装 OpenSSH Client 或用 Git for Windows 自带 ssh。"
    }
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Error "装后仍找不到 ssh。重启 PowerShell 再试。"
}

if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }

# ---------- 2. 写 ssh config ----------
Write-Step "2/3" "写入 $cfg"
if (-not $LocalUser) { Write-Error "LocalUser 为空,中止" }

# 幂等检查
$existing = Select-String -Path $cfg -Pattern '^Host wukong-pc$' -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "config 已有 wukong-pc 段,跳过(若需重建,先删)" -ForegroundColor Yellow
} else {
$block = @"

# ===== ssh-deploy: 通过 FRP 连回本机 Win11 =====
Host wukong-pc
    HostName $VpsHost
    Port $SshPort
    User $LocalUser
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
"@
if (-not (Test-Path $cfg)) { New-Item -ItemType File -Path $cfg -Force | Out-Null }
[System.IO.File]::AppendAllText($cfg, $block, [System.Text.UTF8Encoding]::new($false))
}

# ---------- 3. alias ----------
Write-Step "3/3" "配置 PowerShell alias"
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
if (-not (Select-String -Path $PROFILE -Pattern 'function wukong' -SimpleMatch -Quiet)) {
    [System.IO.File]::AppendAllText($PROFILE, "`n# ssh-deploy alias`nfunction wukong { ssh wukong-pc }`nSet-Alias -Name wpc -Value wukong`n", [System.Text.UTF8Encoding]::new($false))
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "部署完成!" -ForegroundColor Green
Write-Host "  重启 PowerShell 后输: ssh wukong-pc" -ForegroundColor Green
Write-Host "  首次会确认 host key (输 yes)" -ForegroundColor Green
Write-Host "  然后提示输 Win11 账号密码(每次连都要输)" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green