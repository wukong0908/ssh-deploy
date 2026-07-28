<#
.SYNOPSIS
    一键把本机 Win11 配成 SSH 服务器(经 FRP 暴露)。

.DESCRIPTION
    主主机侧一键配置(需管理员跑):
      1. 检查/装 OpenSSH Server
      2. 改 sshd_config:PasswordAuthentication yes + 删 Match Group administrators
      3. 写 frpc 配置(指向主人提供的 VPS / token / 端口)
      4. 注册 frpc 自启任务(SYSTEM / AtLogOn)
      5. 启 sshd + frpc

    链路前提:VPS 上 frps 已跑 + 安全组开放 7000 + 6000。

.PARAMETER VpsHost
    VPS 公网 IP 或域名(FRPS 所在)
.PARAMETER FrpToken
    FRPS 双向校验 token
.PARAMETER FrpSshPort
    FRP 上 SSH 转发的端口(默认 6000)
.PARAMETER LocalUser
    本机 Win11 账号用户名(默认 WuKong)
.PARAMETER FrpcInstallDir
    frpc 装到哪(默认 C:\Tools\frp)

.EXAMPLE
    .\setup-windows.ps1
    # 提示输入 VPS / token / 端口

.EXAMPLE
    .\setup-windows.ps1 -VpsHost 8.163.106.31 -FrpToken "xxx..." -FrpSshPort 6000
#>

[CmdletBinding()]
param(
    [string]$VpsHost,
    [string]$FrpToken,
    [int]$FrpSshPort = 0,  # 0 = 未传,后续交互问
    [string]$LocalUser = '',
    [string]$FrpcInstallDir = 'C:\Tools\frp'
)

$ErrorActionPreference = 'Stop'

# ---------- 0. 交互式收集 ----------
$DEFAULT_VPS = '8.163.106.31'
$DEFAULT_PORT = 6000
$DEFAULT_USER = 'WuKong'

if (-not $VpsHost) {
    $VpsHost = Read-Host "VPS 公网 IP 或域名(FRPS 所在) [$DEFAULT_VPS]"
    if (-not $VpsHost) { $VpsHost = $DEFAULT_VPS }
}
if (-not $VpsHost) { Write-Error "VPS 地址不能为空" }

if (-not $FrpToken) {
    Write-Host "尝试从 VPS 抓 FRPS token(仅当本机已有 VPS 公钥时可用)..." -ForegroundColor Yellow
    $sshBin = Get-Command ssh -ErrorAction SilentlyContinue
    $hasKey = Test-Path "$env:USERPROFILE\.ssh\id_*"
    if ($sshBin -and $hasKey) {
        # 候选:toml / ini / systemd unit file(here-string 防引号转义)
        $cmd = @'
grep -hoE 'token[[:space:]]*=[[:space:]]*"?[A-Za-z0-9._-]+"?' /etc/frp/frps.toml /etc/frp/frps.ini 2>/dev/null; systemctl cat frps 2>/dev/null | grep -hoE 'token[[:space:]]*=[[:space:]]*"?[A-Za-z0-9._-]+"?' | head -1
'@
        try {
            $remote = ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=8 -o BatchMode=yes -o PasswordAuthentication=no "root@$VpsHost" $cmd 2>$null
            $candidates = $remote -split "`n" | ForEach-Object {
                ($_ -replace '^\s*token\s*=\s*"?', '' -replace '"?\s*$', '').Trim()
            } | Where-Object { $_ -and $_ -match '^[A-Za-z0-9._-]{8,}$' }
            if ($candidates) {
                $FrpToken = $candidates[0]
                Write-Host "✅ 从 VPS 拉到 token(长度 $($FrpToken.Length))" -ForegroundColor Green
            }
        } catch {
            Write-Host "⚠️  VPS 抓取失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } elseif (-not $hasKey) {
        Write-Host "⚠️  本机 .ssh 下无 id_* 私钥,跳过自动抓取。" -ForegroundColor Yellow
    }
    if (-not $FrpToken) {
        $secure = Read-Host "FRPS token [回车=跳过 frpc 配置]" -AsSecureString
        if ($secure -and $secure.Length -gt 0) {
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            $FrpToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
        }
    }
}

# 让 param 默认值也走提示(传参时不问)
if ($FrpSshPort -le 0) {
    $portInput = Read-Host "FRP SSH 转发端口 [$DEFAULT_PORT]"
    if ($portInput) { $FrpSshPort = [int]$portInput } else { $FrpSshPort = $DEFAULT_PORT }
}

if (-not $LocalUser) {
    $userInput = Read-Host "本机 Win11 账号用户名 [$DEFAULT_USER]"
    if ($userInput) { $LocalUser = $userInput } else { $LocalUser = $DEFAULT_USER }
}

function Write-Step($n, $msg) {
    Write-Host ""
    Write-Host "[$n/5] $msg" -ForegroundColor Cyan
}

# ---------- 1. OpenSSH Server ----------
Write-Step "1/5" "检查 OpenSSH Server..."
$sshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
$serverCap = (Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction SilentlyContinue) | Where-Object State -eq "Installed"

if (-not $serverCap -and -not (Test-Path $sshdExe)) {
    # 路径 1:从 WinSxS 直拷(秒级,不走 Windows Update)
    $winsxsDirs = Get-ChildItem "$env:SystemRoot\WinSxS\amd64_openssh-server-components-onecore_*" -Directory -ErrorAction SilentlyContinue |
        Sort-Object { [version]($_.Name -split '_')[3] } -Descending
    if ($winsxsDirs) {
        $src = $winsxsDirs[0].FullName
        Write-Host "从 WinSxS 离线装 OpenSSH Server...($src)" -ForegroundColor Cyan
        $dest = "$env:SystemRoot\System32\OpenSSH"
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        # 拷二进制
        Copy-Item -Path "$src\*" -Destination $dest -Recurse -Force
        # 设 ACL(等同 capability 安装结果)
        icacls $dest /inheritance:r /grant "SYSTEM:(R)" "Administrators:(R)" "Users:(RX)" | Out-Null
        icacls "$dest\sshd.exe" /inheritance:r /grant "SYSTEM:(RX)" "Administrators:(RX)" | Out-Null
        # 注册 sshd 服务(Win 默认参数)
        $binPath = "$dest\sshd.exe"
        $existing = Get-Service sshd -ErrorAction SilentlyContinue
        if (-not $existing) {
            sc.exe create sshd binPath= "`"$binPath`"" DisplayName= "OpenSSH SSH Server" start= auto | Out-Null
            sc.exe failure sshd reset= 60 actions= restart/5000 | Out-Null
        }
        # 拷 sshd_config 默认(若 ProgramData 下还没)
        if (-not (Test-Path 'C:\ProgramData\ssh\sshd_config') -and (Test-Path "$src\sshd_config_default")) {
            New-Item -ItemType Directory -Path 'C:\ProgramData\ssh' -Force | Out-Null
            Copy-Item "$src\sshd_config_default" 'C:\ProgramData\ssh\sshd_config' -Force
        }
        # 生成 host keys(若不存在)
        if (-not (Test-Path 'C:\ProgramData\ssh\ssh_host_ed25519_key')) {
            & "$dest\ssh-keygen.exe" -A 2>&1 | Out-Null
        }
        Write-Host "✅ WinSxS 离线装完成" -ForegroundColor Green
    } else {
        # 路径 2:Windows Update(慢)
        Write-Host "WinSxS 无 OpenSSH,走 Windows Update(可能慢)..." -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name "OpenSSH.Server~~~~0.0.1.0" | Out-Null
    }
    Start-Sleep -Seconds 3
    Set-Service sshd -StartupType Automatic
} elseif ($serverCap) {
    Write-Host "OpenSSH Server capability 已装。"
    Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
} else {
    Write-Host "OpenSSH Server 二进制已存在(非 capability 路径)。" -ForegroundColor Cyan
    Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
}

# ---------- 2. sshd_config: PasswordAuthentication + 删 Match ----------
Write-Step "2/5" "改 sshd_config(走 SYSTEM 任务绕 ACL)"
$cfgPath = 'C:\ProgramData\ssh\sshd_config'
$logPath = "$env:TEMP\sshd_setup_log.txt"
$tmpNew = "$env:TEMP\sshd_new.conf"

$content = Get-Content $cfgPath -Raw
$content = $content -replace '(?m)^#?PasswordAuthentication\s+no\s*$', 'PasswordAuthentication yes'
# 删 Match Group administrators 整块(到下一个 Match / EOF,删块后紧跟的空行)
$content = [regex]::Replace($content, '(?ms)^Match Group administrators\b.*?(?=^Match\b|\Z)\r?\n?', '')
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
$tmpBat = "$env:TEMP\sshd_setup.bat"
[System.IO.File]::WriteAllText($tmpBat, $writeScript, [System.Text.UTF8Encoding]::new($false))
$startTime = (Get-Date).AddMinutes(1).ToString('HH:mm')
$taskName = "SshdSetup_$((Get-Date).Ticks)"
schtasks /Create /TN $taskName /SC ONCE /ST $startTime /RU SYSTEM /RL HIGHEST /TR "cmd.exe /c `"$tmpBat`"" /F | Out-Null
schtasks /Run /TN $taskName | Out-Null
Start-Sleep -Seconds 15
schtasks /Delete /TN $taskName /F | Out-Null
Get-Content $logPath
$sshdSvc = Get-Service sshd
if ($sshdSvc.Status -ne 'Running') {
    Write-Error "sshd 未起来。看日志: $logPath"
}
Write-Host "✅ sshd 跑起来了,PasswordAuthentication=yes" -ForegroundColor Green

# ---------- 3. 防火墙 ----------
Write-Step "3/5" "放行 22"
$fwRule = Get-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if (-not $fwRule) {
    New-NetFirewallRule -DisplayName "OpenSSH-Server-In-TCP" -Direction Inbound -LocalPort 22 -Protocol TCP -Action Allow | Out-Null
    Write-Host "防火墙规则已加"
} else {
    Write-Host "防火墙规则已存在"
}

# ---------- 4. frpc 配置 + 自启 ----------
Write-Step "4/5" "frpc 配置 + 自启任务"
if (-not $FrpToken) {
    Write-Host "⚠️  未提供 token,跳过 frpc 配置。" -ForegroundColor Yellow
} else {
    if (-not (Test-Path $FrpcInstallDir)) { New-Item -ItemType Directory -Path $FrpcInstallDir -Force | Out-Null }

    # 下载 frpc(0.61.1,win amd64)
    $frpcExe = Join-Path $FrpcInstallDir 'frpc.exe'
    if (-not (Test-Path $frpcExe)) {
        $url = "https://github.com/fatedier/frp/releases/download/v0.61.1/frp_0.61.1_windows_amd64.zip"
        $zip = "$env:TEMP\frpc.zip"
        Write-Host "下载 frpc..."
        Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
        # 解到临时子目录(避免目标目录污染)
        $expandDir = "$env:TEMP\frpc_expand"
        if (Test-Path $expandDir) { Remove-Item $expandDir -Recurse -Force }
        Expand-Archive -Path $zip -DestinationPath $expandDir -Force
        # 只搬 frpc.exe + LICENSE(扔 frps.exe / frps.toml / frpc.toml 模板 — 本机不需要)
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
        Write-Host "frpc.exe 已存在"
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
    Write-Host "frpc.ini 已写"

    # 注册 schtasks 自启(SYSTEM / AtLogOn / RestartCount 3)
    $schTaskName = 'frpc-autostart'
    $existing = Get-ScheduledTask -TaskName $schTaskName -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName $schTaskName -Confirm:$false
    }
    $action = New-ScheduledTaskAction -Execute $frpcExe -Argument '-c', $iniPath
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $schTaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Host "schtasks $schTaskName 已注册"

    # 立即跑一次
    Start-ScheduledTask -TaskName $schTaskName | Out-Null
    Start-Sleep -Seconds 5
    $frpcProc = Get-Process frpc -ErrorAction SilentlyContinue
    if ($frpcProc) {
        Write-Host "✅ frpc 已启 (PID $($frpcProc.Id))" -ForegroundColor Green
    } else {
        Write-Host "⚠️  frpc 暂未起,等下次登录或手动跑: Start-ScheduledTask frpc-autostart" -ForegroundColor Yellow
    }
}

# ---------- 5. 主人账号密码提示 + 重启 sshd 让新密码生效 ----------
Write-Step "5/5" "主人账号密码检查 + sshd 重启"
try {
    $u = Get-LocalUser -Name $LocalUser -ErrorAction Stop
    if (-not $u.PasswordRequired) {
        Write-Host "⚠️  账号 $LocalUser 还没设密码。" -ForegroundColor Yellow
        Write-Host "    跑:  net user $LocalUser *" -ForegroundColor Yellow
        Write-Host "    设完后跑本脚本一次(或 Restart-Service sshd)让 sshd 重读。" -ForegroundColor Yellow
    } else {
        Write-Host "✅ 账号 $LocalUser 已设密码。" -ForegroundColor Green
    }
} catch {
    Write-Host "⚠️  找不到账号 $LocalUser 。外机连时改对的用户名即可。" -ForegroundColor Yellow
}
# 重启 sshd,确保任何密码变更被立即生效(Win sshd 缓存 SAM 凭证)
try {
    Restart-Service sshd -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    Write-Host "✅ sshd 已重启(sshd 重读 SAM 凭证)" -ForegroundColor Green
} catch {
    Write-Host "⚠️  sshd 重启失败:$($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host "✅ 主机端部署完成!" -ForegroundColor Green
Write-Host "  本机 sshd: $(Get-Service sshd | Select-Object -ExpandProperty Status)" -ForegroundColor Green
Write-Host "  FRP 入口: $VpsHost :$FrpSshPort" -ForegroundColor Green
Write-Host "  外机跑 deploy-windows.ps1 / deploy-android.sh 即可连。" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green