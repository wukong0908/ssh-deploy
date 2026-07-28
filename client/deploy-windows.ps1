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
    [int]$SshPort = 6000,
    [string]$LocalUser
)

$ErrorActionPreference = 'Stop'
$sshDir = "$env:USERPROFILE\.ssh"
$cfg = "$sshDir\config"

function Write-Step($n, $msg) {
    Write-Host ""
    Write-Host "[$n/3] $msg" -ForegroundColor Cyan
}

# ---------- 0. 交互式收集 ----------
if (-not $VpsHost) {
    $VpsHost = Read-Host "VPS 公网 IP 或域名(FRPS 所在)"
    if (-not $VpsHost) { $VpsHost = '8.163.106.31' }
}
if (-not $LocalUser) {
    $LocalUser = Read-Host "本机 Win11 的账号用户名(例如 WuKong)"
}

# ---------- 1. OpenSSH Client ----------
Write-Step "1/3" "检查 OpenSSH Client..."
$cap = (Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction SilentlyContinue) | Where-Object State -eq "Installed"
if (-not $cap) {
    Write-Host "正在安装 OpenSSH Client..."
    Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" | Out-Null
} else {
    Write-Host "OpenSSH Client 已安装。"
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Error "安装后仍找不到 ssh。重启 PowerShell 再试。"
}

if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }

# ---------- 2. 写 ssh config ----------
Write-Step "2/3" "写入 $cfg"
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
Add-Content -Path $cfg -Value $block -Encoding UTF8

# ---------- 3. alias ----------
Write-Step "3/3" "配置 PowerShell alias"
$profileDir = Split-Path $PROFILE -Parent
if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }
if (-not (Select-String -Path $PROFILE -Pattern 'function wukong' -SimpleMatch -Quiet)) {
    Add-Content -Path $PROFILE -Value "`n# ssh-deploy alias`nfunction wukong { ssh wukong-pc }`nSet-Alias -Name wpc -Value wukong`n" -Encoding UTF8
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "部署完成!" -ForegroundColor Green
Write-Host "  重启 PowerShell 后输: ssh wukong-pc" -ForegroundColor Green
Write-Host "  首次会确认 host key (输 yes)" -ForegroundColor Green
Write-Host "  然后提示输 Win11 账号密码(每次连都要输)" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green