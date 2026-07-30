<#
.SYNOPSIS
    Win11 一脚本 ssh-deploy(默认双向:服务端 + 客户端).

.DESCRIPTION
    一次跑装成 Win 双向:
      - 服务端能力:sshd 跑 + frpc 启(对外转发自己的 :22) → 别人能 SSH 进
      - 客户端能力:拉 VPS JSON → 写 ~/.ssh/config 多 Host wpc-* 段 → 主人能 SSH 出

    主菜单:
      [1] Install (default: server + client both)
      [2] Status
      [3] Switch (重命名 alias)
      [4] Register this host to VPS directory
      [5] Unregister this host
      [0] Exit

.PARAMETER VpsHost
    VPS 公网 IP(frps + ssh-deploy-api 所在)
.PARAMETER BearerToken
    ssh-deploy-api 的 Bearer token(主人 VPS 上自定,与 vps/INSTALL.md 一致)
.PARAMETER FrpToken
    FRPS 双向校验 token(可留空,会跳过 frpc 配)
.PARAMETER LocalUser
    本机 Win11 账号(SSH 连入用),默认 WuKong
.PARAMETER FrpSshPort
    frp 转 SSH 端口(默认 6000)
.PARAMETER ServerName
    VPS 注册名(默认 = $env:COMPUTERNAME 小写)
.PARAMETER InstallMode
    'both'(默认)/ 'server' / 'client'

.EXAMPLE
    irm https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/win/ssh-deploy.ps1 | iex
    # 交互式
#>

[CmdletBinding()]
param(
    [string]$VpsHost,
    [string]$BearerToken,
    [string]$FrpToken,
    [string]$LocalUser = '',
    [int]$FrpSshPort = 0,
    [string]$ServerName,
    [ValidateSet('both','server','client')]
    [string]$InstallMode = 'both'
)

$ErrorActionPreference = 'Stop'

# ---------- 常量 ----------
$DEFAULT_VPS = '8.163.106.31'
$DEFAULT_PORT = 6000
$DEFAULT_USER = 'WuKong'
$OPENSSH_ZIP_NAME = 'OpenSSH-Win64.zip'
$OPENSSH_GH_URL = 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/openssh/OpenSSH-Win64.zip'
$FRP_VERSION = '0.61.1'
$FRP_URL = "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_windows_amd64.zip"
$FrpcInstallDir = 'C:\Tools\frp'
$sshDir = "$env:USERPROFILE\.ssh"
$cfg = "$sshDir\config"

# ---------- helper: OpenSSH zip ----------
function Get-OpenSSHZip {
    param([string]$WorkDir)
    if ($PSCommandPath) {
        $scriptDir = Split-Path $PSCommandPath -Parent
        $candidates = @(
            (Join-Path $scriptDir "..\bin\openssh\$OPENSSH_ZIP_NAME"),
            (Join-Path $scriptDir "bin\openssh\$OPENSSH_ZIP_NAME")
        )
        foreach ($p in $candidates) {
            if (Test-Path $p) { return @{ path = $p; source = 'local' } }
        }
    }
    $localZip = Join-Path $WorkDir $OPENSSH_ZIP_NAME
    if (Test-Path $localZip -PathType Leaf) {
        return @{ path = $localZip; source = 'cached' }
    }
    Write-Host "下载离线 OpenSSH 包(从 GitHub raw)..." -ForegroundColor Cyan
    try {
        Invoke-WebRequest -Uri $OPENSSH_GH_URL -OutFile $localZip -UseBasicParsing -ErrorAction Stop
        return @{ path = $localZip; source = 'github-raw' }
    } catch {
        Write-Host "⚠️  GitHub 下载失败:$($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Expand-OpenSSHZip {
    param([string]$ZipPath, [string]$ExpandRoot)
    $expandDir = Join-Path $ExpandRoot 'openssh_expand'
    if (Test-Path $expandDir) { Remove-Item $expandDir -Recurse -Force }
    Expand-Archive -Path $ZipPath -DestinationPath $expandDir -Force
    $sub = Get-ChildItem $expandDir -Directory | Where-Object Name -like 'OpenSSH-Win64' | Select-Object -First 1
    if (-not $sub) { throw "zip 内找不到 OpenSSH-Win64 子目录" }
    return $sub.FullName
}

# ---------- helper: VPS API ----------
function Get-VpsHeaders {
    if (-not $BearerToken) { return @{} }
    return @{ 'Authorization' = "Bearer $BearerToken" }
}

function Get-VpsHostsJson {
    if (-not $VpsHost -or -not $BearerToken) { return $null }
    try {
        $url = "http://${VpsHost}:8080/ssh-deploy/hosts"
        $resp = Invoke-RestMethod -Uri $url -Headers (Get-VpsHeaders) -TimeoutSec 8 -ErrorAction Stop
        return $resp
    } catch {
        Write-Host "⚠️  拉 VPS hosts 失败:$($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Register-ThisHost {
    if (-not $VpsHost -or -not $BearerToken) {
        Write-Host "需要 -VpsHost + -BearerToken" -ForegroundColor Yellow
        return
    }
    $payload = @{
        name = $ServerName
        vps_host = $VpsHost
        ssh_port = $FrpSshPort
        ssh_user = $LocalUser
        alias = "wpc-$ServerName"
        desc = $env:COMPUTERNAME
    } | ConvertTo-Json -Compress
    try {
        $url = "http://${VpsHost}:8080/ssh-deploy/register"
        $resp = Invoke-RestMethod -Uri $url -Method POST -ContentType 'application/json' -Headers (Get-VpsHeaders) -Body $payload -TimeoutSec 8 -ErrorAction Stop
        Write-Host "✅ 已注册 $($resp.registered.name) → port $($resp.registered.ssh_port) user $($resp.registered.ssh_user)" -ForegroundColor Green
    } catch {
        Write-Host "❌ register 失败:$($_.Exception.Message)" -ForegroundColor Red
    }
}

function Unregister-ThisHost {
    if (-not $VpsHost -or -not $BearerToken) {
        Write-Host "需要 -VpsHost + -BearerToken" -ForegroundColor Yellow
        return
    }
    $payload = @{ name = $ServerName } | ConvertTo-Json -Compress
    try {
        $url = "http://${VpsHost}:8080/ssh-deploy/unregister"
        $resp = Invoke-RestMethod -Uri $url -Method POST -ContentType 'application/json' -Headers (Get-VpsHeaders) -Body $payload -TimeoutSec 8 -ErrorAction Stop
        Write-Host "✅ 已注销 $($ServerName)(移除 $($resp.removed) 条)" -ForegroundColor Green
    } catch {
        Write-Host "❌ unregister 失败:$($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------- helper: SSH config 生成 ----------
function Generate-SSHConfigFromVPS {
    param([string]$DefaultVps)
    $hosts = Get-VpsHostsJson
    if (-not $hosts -or -not $hosts.servers) {
        Write-Host "VPS 无主机清单(空或拉取失败),跳过 SSH config 生成" -ForegroundColor Yellow
        return
    }
    # 备份现有 config
    if (Test-Path $cfg) {
        $bak = "$cfg.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $cfg $bak -Force
        Write-Host "config 已备份 → $bak" -ForegroundColor DarkGray
    }
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    if (-not (Test-Path $cfg)) { New-Item -ItemType File -Path $cfg -Force | Out-Null }

    # 先删旧 ssh-deploy 段
    $content = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
    if ($content) {
        $content = [regex]::Replace($content, '(?ms)# ===== ssh-deploy:.*?# ===== END ssh-deploy =====\r?\n?', '')
        [System.IO.File]::WriteAllText($cfg, $content, [System.Text.UTF8Encoding]::new($false))
    }

    # 逐 server 写
    foreach ($s in $hosts.servers) {
        $vps = if ($s.vps_host) { $s.vps_host } else { $DefaultVps }
        $segment = @"

# ===== ssh-deploy: $($s.name) =====
Host $($s.alias)
    HostName $vps
    Port $($s.ssh_port)
    User $($s.ssh_user)
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
"@
        [System.IO.File]::AppendAllText($cfg, $segment, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✅ alias $($s.alias) → $vps :$($s.ssh_port) user $($s.ssh_user)" -ForegroundColor Green
    }
}

# ---------- helper: Write-Step ----------
function Write-Step($n, $msg) {
    Write-Host ""
    Write-Host "[$n] $msg" -ForegroundColor Cyan
}

# ---------- helper: 交互式收集 ----------
if (-not $VpsHost) {
    $VpsHost = Read-Host "VPS 公网 IP [$DEFAULT_VPS]"
    if (-not $VpsHost) { $VpsHost = $DEFAULT_VPS }
}
if (-not $BearerToken) {
    $BearerToken = Read-Host "ssh-deploy-api Bearer token(留空=不调 VPS API)"
    if (-not $BearerToken) { $BearerToken = '' }
}
if ($FrpSshPort -le 0) {
    $portInput = Read-Host "FRP SSH 转发端口 [$DEFAULT_PORT]"
    if ($portInput) { $FrpSshPort = [int]$portInput } else { $FrpSshPort = $DEFAULT_PORT }
}
if (-not $LocalUser) {
    $userInput = Read-Host "本机 Win11 账号用户名 [$DEFAULT_USER]"
    if ($userInput) { $LocalUser = $userInput } else { $LocalUser = $DEFAULT_USER }
}
if (-not $LocalUser) { Write-Error "用户名不能为空" }
if (-not $ServerName) {
    $defaultName = $env:COMPUTERNAME.ToLower()
    $nameInput = Read-Host "VPS 注册名 [$defaultName]"
    if ($nameInput) { $ServerName = $nameInput } else { $ServerName = $defaultName }
}

# ---------- 1. OpenSSH Server install ----------
function Install-OpenSSHServer {
    Write-Step "S1" "装 OpenSSH Server"
    $sshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
    $serverCap = (Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue) | Where-Object State -eq 'Installed'

    if ($serverCap -or (Test-Path $sshdExe)) {
        Write-Host "OpenSSH Server 已就绪" -ForegroundColor Cyan
        Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
        return
    }

    $dest = "$env:SystemRoot\System32\OpenSSH"
    $expandRoot = "$env:TEMP\openssh_setup"
    if (-not (Test-Path $expandRoot)) { New-Item -ItemType Directory -Path $expandRoot -Force | Out-Null }
    $installed = $false

    $zipInfo = Get-OpenSSHZip -WorkDir $expandRoot
    if ($zipInfo) {
        Write-Host "从 $($zipInfo.source) 解压 OpenSSH..." -ForegroundColor Cyan
        try {
            $src = Expand-OpenSSHZip -ZipPath $zipInfo.path -ExpandRoot $expandRoot
            $installed = $true
        } catch {
            Write-Host "⚠️  zip 解压失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    if (-not $installed) {
        $winsxsDirs = Get-ChildItem "$env:SystemRoot\WinSxS\amd64_openssh-server-components-onecore_*" -Directory -ErrorAction SilentlyContinue |
            Sort-Object { [version]($_.Name -split '_')[3] } -Descending
        if ($winsxsDirs) {
            $src = $winsxsDirs[0].FullName
            Write-Host "从 WinSxS 装 OpenSSH Server...($src)" -ForegroundColor Cyan
            $installed = $true
        }
    }
    if ($installed) {
        $logPath = "$env:TEMP\openssh_install_log.txt"
        $tmpBat = "$env:TEMP\openssh_install.bat"
        $writeScript = @"
@echo off
setlocal
chcp 65001 >nul
set LOG=$logPath
echo START %date% %time% > "%LOG%"
if not exist "$dest" mkdir "$dest" >> "%LOG%" 2>&1
xcopy /Y /E /I "$src\*" "$dest\" >> "%LOG%" 2>&1
echo xcopy exit=%errorlevel% >> "%LOG%"
icacls "$dest" /inheritance:r /grant "SYSTEM:(R)" "Administrators:(R)" "Users:(RX)" >> "%LOG%" 2>&1
icacls "$dest\sshd.exe" /inheritance:r /grant "SYSTEM:(RX)" "Administrators:(RX)" >> "%LOG%" 2>&1
if not exist "C:\ProgramData\ssh" mkdir "C:\ProgramData\ssh" >> "%LOG%" 2>&1
if exist "$src\sshd_config_default" copy /Y "$src\sshd_config_default" "C:\ProgramData\ssh\sshd_config" >> "%LOG%" 2>&1
"C:\Windows\System32\OpenSSH\ssh-keygen.exe" -A >> "%LOG%" 2>&1
sc create sshd binPath= "\"$dest\sshd.exe\"" DisplayName= "OpenSSH SSH Server" start= auto >> "%LOG%" 2>&1
sc failure sshd reset= 60 actions= restart/5000 >> "%LOG%" 2>&1
echo END >> "%LOG%"
endlocal
"@
        [System.IO.File]::WriteAllText($tmpBat, $writeScript, [System.Text.UTF8Encoding]::new($false))
        $startTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
        $taskName = "OpenSSHInstall_$((Get-Date).Ticks)"
        schtasks /Create /TN $taskName /SC ONCE /ST $startTime /RU SYSTEM /RL HIGHEST /TR "cmd.exe /c `"$tmpBat`"" /F | Out-Null
        schtasks /Run /TN $taskName | Out-Null
        Start-Sleep -Seconds 15
        schtasks /Delete /TN $taskName /F | Out-Null
        Get-Content $logPath
        Remove-Item $tmpBat -Force -ErrorAction SilentlyContinue
        Write-Host "✅ OpenSSH Server 装完" -ForegroundColor Green
    } else {
        Write-Host "zip + WinSxS 都不可用,走 Windows Update(慢)..." -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
    Start-Sleep -Seconds 3
    Set-Service sshd -StartupType Automatic
}

# ---------- 2. sshd_config: PasswordAuthentication + 删 Match ----------
function Set-SshdConfig {
    Write-Step "S2" "改 sshd_config"
    $cfgPath = 'C:\ProgramData\ssh\sshd_config'
    if (-not (Test-Path $cfgPath)) {
        Write-Host "⚠️  $cfgPath 不存在 — 跳过(可能 OpenSSH Server 未装)" -ForegroundColor Yellow
        return
    }
    $content = Get-Content $cfgPath -Raw
    $content = $content -replace '(?m)^#?PasswordAuthentication\s+no\s*$', 'PasswordAuthentication yes'
    $content = [regex]::Replace($content, '(?ms)^Match Group administrators\b.*?(?=^Match\b|\Z)\r?\n?', '')
    $logPath = "$env:TEMP\sshd_setup_log.txt"
    $tmpNew = "$env:TEMP\sshd_new.conf"
    $tmpBat = "$env:TEMP\sshd_setup.bat"
    [System.IO.File]::WriteAllText($tmpNew, $content, [System.Text.UTF8Encoding]::new($false))

    $writeScript = @"
@echo off
setlocal
chcp 65001 >nul
set LOG=$logPath
echo START %date% %time% > "%LOG%"
sc stop sshd >> "%LOG%" 2>&1
ping -n 3 127.0.0.1 >nul
copy /Y "$tmpNew" "$cfgPath" >> "%LOG%" 2>&1
icacls "$cfgPath" /inheritance:r >> "%LOG%" 2>&1
icacls "$cfgPath" /grant:r "NT AUTHORITY\SYSTEM:(R)" "BUILTIN\Administrators:(R)" >> "%LOG%" 2>&1
"C:\Program Files\OpenSSH\sshd.exe" -t -f "$cfgPath" >> "%LOG%" 2>&1
sc start sshd >> "%LOG%" 2>&1
ping -n 3 127.0.0.1 >nul
sc query sshd >> "%LOG%" 2>&1
endlocal
"@
    [System.IO.File]::WriteAllText($tmpBat, $writeScript, [System.Text.UTF8Encoding]::new($false))
    $startTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
    $taskName = "SshdSetup_$((Get-Date).Ticks)"
    schtasks /Create /TN $taskName /SC ONCE /ST $startTime /RU SYSTEM /RL HIGHEST /TR "cmd.exe /c `"$tmpBat`"" /F | Out-Null
    schtasks /Run /TN $taskName | Out-Null
    Start-Sleep -Seconds 15
    schtasks /Delete /TN $taskName /F | Out-Null
    Get-Content $logPath
    Remove-Item $tmpBat -Force -ErrorAction SilentlyContinue

    $svc = Get-Service sshd
    if ($svc.Status -ne 'Running') {
        Write-Error "sshd 未起来。看日志:$logPath"
    }
    Write-Host "✅ sshd 跑起来了,PasswordAuthentication=yes" -ForegroundColor Green
}

# ---------- 3. 防火墙 22 ----------
function Add-FirewallRule22 {
    Write-Step "S3" "放行 22"
    $fwRule = Get-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if (-not $fwRule) {
        New-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP' -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow | Out-Null
        Write-Host "防火墙规则已加" -ForegroundColor Green
    } else {
        Write-Host "防火墙规则已存在" -ForegroundColor Cyan
    }
}

# ---------- 4. OpenSSH Client install ----------
function Install-OpenSSHClient {
    Write-Step "C1" "装 OpenSSH Client"
    $dest = "$env:SystemRoot\System32\OpenSSH"
    $sshExe = "$dest\ssh.exe"
    if (Test-Path $sshExe) {
        Write-Host "ssh.exe 已存在" -ForegroundColor Cyan
        return
    }
    $expandRoot = "$env:TEMP\openssh_setup"
    if (-not (Test-Path $expandRoot)) { New-Item -ItemType Directory -Path $expandRoot -Force | Out-Null }
    $installed = $false

    $zipInfo = Get-OpenSSHZip -WorkDir $expandRoot
    if ($zipInfo) {
        Write-Host "从 $($zipInfo.source) 解压 OpenSSH Client..." -ForegroundColor Cyan
        try {
            $src = Expand-OpenSSHZip -ZipPath $zipInfo.path -ExpandRoot $expandRoot
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            Copy-Item -Path "$src\*" -Destination $dest -Recurse -Force
            Write-Host "✅ 从 zip 解 Client 到 $dest" -ForegroundColor Green
            $installed = $true
        } catch {
            Write-Host "⚠️  zip 解压失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
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
    if (-not $installed) {
        Write-Host "zip + WinSxS 都没,走 Windows Update(慢)..." -ForegroundColor Yellow
        try {
            Add-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction Stop | Out-Null
            $installed = $true
        } catch {
            Write-Error "OpenSSH Client 装失败:$_"
        }
    }
    if (-not (Test-Path $sshExe)) {
        Write-Error "找不到 ssh.exe。重启 PowerShell 再试。"
    }
}

# ---------- 5. frpc install ----------
function Install-Frpc {
    Write-Step "S4" "frpc 配置 + 自启"
    if (-not $FrpToken) {
        Write-Host "⚠️  未提供 FrpToken,跳过 frpc 配置" -ForegroundColor Yellow
        return
    }
    if (-not (Test-Path $FrpcInstallDir)) { New-Item -ItemType Directory -Path $FrpcInstallDir -Force | Out-Null }

    $frpcExe = Join-Path $FrpcInstallDir 'frpc.exe'
    if (-not (Test-Path $frpcExe)) {
        $url = "https://github.com/fatedier/frp/releases/download/v${FRP_VERSION}/frp_${FRP_VERSION}_windows_amd64.zip"
        $zip = "$env:TEMP\frpc.zip"
        Write-Host "下载 frpc..." -ForegroundColor Cyan
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        $expandDir = "$env:TEMP\frpc_expand"
        if (Test-Path $expandDir) { Remove-Item $expandDir -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $expandDir -Force
        $srcSub = Get-ChildItem $expandDir -Directory | Where-Object Name -like 'frp_*' | Select-Object -First 1
        if ($srcSub) {
            foreach ($f in 'frpc.exe') {
                $srcFile = Join-Path $srcSub.FullName $f
                if (Test-Path $srcFile) { Move-Item $srcFile $FrpcInstallDir -Force }
            }
            $licSrc = Join-Path $srcSub.FullName 'LICENSE'
            if (Test-Path $licSrc) { Move-Item $licSrc $FrpcInstallDir -Force -ErrorAction SilentlyContinue }
        }
        Remove-Item $expandDir -Recurse -Force
        Remove-Item $zip -Force -ErrorAction SilentlyContinue
    } else {
        Write-Host "frpc.exe 已存在" -ForegroundColor Cyan
    }

    $iniPath = Join-Path $FrpcInstallDir 'frpc.ini'
    $ini = @"

[common]
server_addr = $VpsHost
server_port = 7000
token = $FrpToken

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = $FrpSshPort
"@
    [System.IO.File]::WriteAllText($iniPath, $ini, [System.Text.UTF8Encoding]::new($false))
    Write-Host "frpc.ini 已写" -ForegroundColor Cyan

    $schTaskName = 'frpc-autostart'
    $existing = Get-ScheduledTask -TaskName $schTaskName -ErrorAction SilentlyContinue
    if ($existing) { Unregister-ScheduledTask -TaskName $schTaskName -Confirm:$false }
    $action = New-ScheduledTaskAction -Execute $frpcExe -Argument "-c `"$iniPath`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $schTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "schtasks $schTaskName 已注册" -ForegroundColor Cyan

    Start-ScheduledTask -TaskName $schTaskName | Out-Null
    Start-Sleep -Seconds 5
    $frpcProc = Get-Process frpc -ErrorAction SilentlyContinue
    if ($frpcProc) {
        Write-Host "✅ frpc 已启 (PID $($frpcProc.Id))" -ForegroundColor Green
    } else {
        Write-Host "⚠️  frpc 暂未起,等下次登录或手动: Start-ScheduledTask frpc-autostart" -ForegroundColor Yellow
    }
}

# ---------- 6. 账号密码检查 + sshd 重启 ----------
function Test-AccountAndRestartSshd {
    Write-Step "S5" "主人账号密码检查 + sshd 重启"
    try {
        $u = Get-LocalUser -Name $LocalUser -ErrorAction Stop
        if (-not $u.PasswordRequired) {
            Write-Host "⚠️  账号 $LocalUser 还没设密码。" -ForegroundColor Yellow
            Write-Host "    跑:  net user $LocalUser *" -ForegroundColor Yellow
            Write-Host "    设完后跑本脚本(或 Restart-Service sshd)让 sshd 重读。" -ForegroundColor Yellow
        } else {
            Write-Host "✅ 账号 $LocalUser 已设密码。" -ForegroundColor Green
        }
    } catch {
        Write-Host "⚠️  找不到账号 $LocalUser" -ForegroundColor Yellow
    }
    try {
        Restart-Service sshd -Force -ErrorAction Stop
        Start-Sleep -Seconds 2
        Write-Host "✅ sshd 已重启" -ForegroundColor Green
    } catch {
        Write-Host "⚠️  sshd 重启失败:$($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------- 7. PowerShell alias ----------
function Add-PowerShellAliases {
    Write-Step "C2" "配置 PowerShell alias(wpc-* 一键 SSH)"
    $profileDir = Split-Path $PROFILE -Parent
    if (-not (Test-Path $profileDir)) { New-Item -ItemType Directory -Path $profileDir -Force | Out-Null }
    if (-not (Test-Path $PROFILE)) { New-Item -ItemType File -Path $PROFILE -Force | Out-Null }

    $hosts = Get-VpsHostsJson
    if (-not $hosts -or -not $hosts.servers) {
        Write-Host "VPS 无主机清单,跳过 alias 写入" -ForegroundColor Yellow
        return
    }
    # 先删旧 ssh-deploy alias 段
    $pc = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
    if ($pc) {
        $pc = [regex]::Replace($pc, '(?ms)# ===== ssh-deploy aliases =====.*?# ===== END ssh-deploy aliases =====\r?\n?', '')
        [System.IO.File]::WriteAllText($PROFILE, $pc, [System.Text.UTF8Encoding]::new($false))
    }
    $aliasBlock = "`n# ===== ssh-deploy aliases ====="
    foreach ($s in $hosts.servers) {
        $fn = "ssh-$($s.name)"
        $aliasBlock += "`nfunction $fn { ssh $($s.alias) }`nSet-Alias -Name wpc-$($s.name) -Value $fn`n"
    }
    $aliasBlock += "# ===== END ssh-deploy aliases =====`n"
    [System.IO.File]::AppendAllText($PROFILE, $aliasBlock, [System.Text.UTF8Encoding]::new($false))
    Write-Host "✅ 已写 $($hosts.servers.Count) 个 alias(wpc-<name>)" -ForegroundColor Green
}

# ---------- Status ----------
function Show-Status {
    Write-Host "`n========== ssh-deploy Status ==========" -ForegroundColor Cyan
    Write-Host "主机名: $env:COMPUTERNAME"
    Write-Host "VPS:    $VpsHost"
    Write-Host ""
    # sshd
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Host "sshd: $($svc.Status) / $($svc.StartType)" -ForegroundColor $(if ($svc.Status -eq 'Running') { 'Green' } else { 'Yellow' })
    } else {
        Write-Host "sshd: 未装" -ForegroundColor Yellow
    }
    # ssh.exe
    $sshCmd = Get-Command ssh -ErrorAction SilentlyContinue
    if ($sshCmd) {
        Write-Host "ssh.exe: $($sshCmd.Source)" -ForegroundColor Green
    } else {
        Write-Host "ssh.exe: 未装" -ForegroundColor Yellow
    }
    # frpc
    $frpcProc = Get-Process frpc -ErrorAction SilentlyContinue
    $frpcTask = Get-ScheduledTask frpc-autostart -ErrorAction SilentlyContinue
    if ($frpcProc) {
        Write-Host "frpc: PID $($frpcProc.Id) running" -ForegroundColor Green
    } else {
        Write-Host "frpc: 未跑" -ForegroundColor Yellow
    }
    if ($frpcTask) {
        Write-Host "frpc-autostart: $($frpcTask.State)" -ForegroundColor Green
    }
    # 22 端口
    $conn = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    if ($conn) {
        Write-Host "port 22: LISTEN" -ForegroundColor Green
    } else {
        Write-Host "port 22: NOT LISTEN" -ForegroundColor Yellow
    }
    # VPS hosts
    Write-Host ""
    Write-Host "--- VPS 注册主机 ---" -ForegroundColor Cyan
    $hosts = Get-VpsHostsJson
    if ($hosts -and $hosts.servers) {
        foreach ($s in $hosts.servers) {
            Write-Host ("  {0,-10} port {1,-5} user {2,-10} alias {3}" -f $s.name, $s.ssh_port, $s.ssh_user, $s.alias) -ForegroundColor Green
        }
    } else {
        Write-Host "  (无 / 拉不到)" -ForegroundColor Yellow
    }
    # 本机 config
    Write-Host ""
    Write-Host "--- ~/.ssh/config (wpc-* 段) ---" -ForegroundColor Cyan
    if (Test-Path $cfg) {
        $matches = Select-String -Path $cfg -Pattern '^Host wpc-' -ErrorAction SilentlyContinue
        if ($matches) {
            foreach ($m in $matches) { Write-Host "  $($m.Line)" }
        } else {
            Write-Host "  (无)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  (config 不存在)" -ForegroundColor Yellow
    }
    Write-Host "=========================================" -ForegroundColor Cyan
}

# ---------- Switch (重生成 alias;主用 ssh <alias> 不需要切换) ----------
function Switch-Alias {
    Write-Host ""
    Write-Host "Switch:重新拉 VPS 清单 + 重写 ~/.ssh/config + PowerShell alias" -ForegroundColor Cyan
    Generate-SSHConfigFromVPS -DefaultVps $VpsHost
    Add-PowerShellAliases
    Write-Host "✅ switch 完成。重启 PowerShell 后生效。" -ForegroundColor Green
}

# ---------- 主流程:Install ----------
function Invoke-Install {
    Write-Host ""
    Write-Host "====== Install (mode=$InstallMode) ======" -ForegroundColor Cyan
    if ($InstallMode -in 'both','server') {
        Install-OpenSSHServer
        Set-SshdConfig
        Add-FirewallRule22
        Install-Frpc
        Test-AccountAndRestartSshd
    }
    if ($InstallMode -in 'both','client') {
        Install-OpenSSHClient
        # 拉 VPS 清单 → 写 config
        Write-Step "C2" "拉 VPS 主机清单 → 写 ~/.ssh/config"
        Generate-SSHConfigFromVPS -DefaultVps $VpsHost
        Add-PowerShellAliases
    }
    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "✅ 部署完成!" -ForegroundColor Green
    if ($InstallMode -in 'both','server') {
        Write-Host "  本机 sshd: $(Get-Service sshd | Select-Object -ExpandProperty Status)" -ForegroundColor Green
        Write-Host "  FRP 入口:  $VpsHost :$FrpSshPort" -ForegroundColor Green
    }
    if ($InstallMode -in 'both','client') {
        Write-Host "  本机 ssh:  $(Get-Command ssh | Select-Object -ExpandProperty Source)" -ForegroundColor Green
        Write-Host "  VPS 主机数:从 VPS 拉 → ~/.ssh/config 多 Host wpc-* 段" -ForegroundColor Green
    }
    # 可选 register
    if ($VpsHost -and $BearerToken) {
        Write-Host ""
        $ans = Read-Host "要立即把本机 register 到 VPS 目录吗? [y/N]"
        if ($ans -eq 'y' -or $ans -eq 'Y') {
            Register-ThisHost
        }
    }
    Write-Host "============================================" -ForegroundColor Green
}

# ---------- 主菜单 ----------
function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "========== ssh-deploy ($env:COMPUTERNAME) =========" -ForegroundColor Cyan
        Write-Host "  [1] Install (default: server + client both)"
        Write-Host "  [2] Status"
        Write-Host "  [3] Switch (重拉 VPS 清单)"
        Write-Host "  [4] Register this host to VPS directory"
        Write-Host "  [5] Unregister this host"
        Write-Host "  [0] Exit"
        Write-Host "===========================================" -ForegroundColor Cyan
        $choice = Read-Host "选择 [0-5]"
        switch ($choice) {
            '1' { Invoke-Install }
            '2' { Show-Status }
            '3' { Switch-Alias }
            '4' { Register-ThisHost }
            '5' { Unregister-ThisHost }
            '0' { return }
            default { Write-Host "无效输入" -ForegroundColor Yellow }
        }
    }
}

# ---------- 入口 ----------
if ($InstallMode -or $VpsHost -or $BearerToken) {
    # 传参跑 → 直接 install(可脚本化)
    Invoke-Install
} else {
    Show-Menu
}