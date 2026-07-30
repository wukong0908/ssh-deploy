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

# 找 zip 路径:脚本本地 bin/ 或 GitHub raw(irm|iex 场景)
$OPENSSH_ZIP_NAME = 'OpenSSH-Win64.zip'
$OPENSSH_GH_URL = 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/openssh/OpenSSH-Win64.zip'

function Get-OpenSSHZip {
    param([string]$WorkDir)
    if ($PSCommandPath) {
        $scriptDir = Split-Path $PSCommandPath -Parent
        $candidates = @(
            (Join-Path $scriptDir "..\bin\openssh\$OPENSSH_ZIP_NAME"),
            (Join-Path $scriptDir "bin\openssh\$OPENSSH_ZIP_NAME")
        )
        foreach ($p in $candidates) {
            if (Test-Path $p) { return @{ path = $p; source = "local" } }
        }
    }
    $localZip = Join-Path $WorkDir $OPENSSH_ZIP_NAME
    if (Test-Path $localZip -PathType Leaf) {
        return @{ path = $localZip; source = "cached" }
    }
    Write-Host "下载离线 OpenSSH 包(从 GitHub raw)..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $OPENSSH_GH_URL -OutFile $localZip -UseBasicParsing -ErrorAction Stop
        return @{ path = $localZip; source = "github-raw" }
    } catch {
        Write-Host "⚠️  GitHub 下载失败:$($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
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
$dest = "$env:SystemRoot\System32\OpenSSH"
$sshExe = "$dest\ssh.exe"
$hasCap = $true
try {
    $cap = (Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction SilentlyContinue) | Where-Object State -eq "Installed"
    if (-not $cap) {
        Write-Host "正在装 OpenSSH Client(走三级优先级:zip → WinSxS → Win Update)..."
    } else {
        Write-Host "OpenSSH Client capability 已装。"
    }
} catch {
    Write-Host "⚠️  Get-WindowsCapability 失败:$_" -ForegroundColor Yellow
    $hasCap = $false
}

if (-not (Test-Path $sshExe)) {
    $expandRoot = "$env:TEMP\openssh_setup"
    if (-not (Test-Path $expandRoot)) { New-Item -ItemType Directory -Path $expandRoot -Force | Out-Null }
    $installed = $false

    # 路径 1:仓内 zip / GitHub raw
    $zipInfo = Get-OpenSSHZip -WorkDir $expandRoot
    if ($zipInfo) {
        Write-Host "从 $($zipInfo.source) 解压 OpenSSH Client..." -ForegroundColor Cyan
        try {
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Expand-Archive -Path $zipInfo.path -DestinationPath $expandRoot -Force
            $sub = Get-ChildItem $expandRoot -Directory | Where-Object Name -like 'OpenSSH-Win64' | Select-Object -First 1
            if ($sub) {
                # medium-IL 可写 System32\OpenSSH
                Copy-Item -Path "$($sub.FullName)\*" -Destination $dest -Recurse -Force
                Write-Host "✅ 从 zip 解 OpenSSH Client 到 $dest" -ForegroundColor Green
                $installed = $true
            }
        } catch {
            Write-Host "⚠️  zip 解压失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # 路径 2:WinSxS
    if (-not $installed) {
        $winsxsDirs = Get-ChildItem "$env:SystemRoot\WinSxS\amd64_openssh-client-components-onecore_*" -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [version]($_.Name -split '_')[3] } -Descending
        if ($winsxsDirs) {
            $src = $winsxsDirs[0].FullName
            Write-Host "从 WinSxS 拷 OpenSSH Client...($src)" -ForegroundColor Cyan
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Copy-Item -Path "$src\*" -Destination $dest -Recurse -Force -ErrorAction SilentlyContinue
            $installed = $true
        }
    }

    # 路径 3:Windows Update
    if (-not $installed) {
        Write-Host "WinSxS + zip 都没,走 Windows Update(可能慢)..." -ForegroundColor Yellow
        try {
            Add-WindowsCapability -Online -Name "OpenSSH.Client~~~~0.0.1.0" -ErrorAction Stop | Out-Null
            $installed = $true
        } catch {
            Write-Error "OpenSSH Client 装失败。看 $_"
        }
    }
}

if (-not (Test-Path $sshExe)) {
    Write-Error "找不到 ssh.exe。重启 PowerShell 再试,或手动装 OpenSSH Client。"
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