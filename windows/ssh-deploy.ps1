<#
.SYNOPSIS
    Win11 ssh-deploy 部署脚本 v3 (重构 + 4 bug 修复)

.DESCRIPTION
    一次跑装成 Win 双向:
      - 服务端能力:sshd 跑 + frpc 启(对外转发自己的 :22) → 别人能 SSH 进
      - 客户端能力:拉 VPS JSON → 写 ~/.ssh/config 多 Host wpc-* 段 → 主人能 SSH 出

    v3 改动 (2026-08-03):
      - 5 region 模块化 (Module 0 Logging / 1 PreFlight / 2 Install / 3 Network / 4 Register / 5 Menu / 6 Uninstall / 7 State)
      - 错误分级 Write-Info / Ok / Warn / Err (-Critical) — Critical 停序列
      - 4 bug 修: frpc 3-tier 来源(bundled→installed→网络 retry) / HttpClient 30s timeout + 3× retry /
                 密码检查变 Critical guard / 错误不再吞 (LastError 持久)
      - 单一源: 1 个 Invoke-VpsApi / 1 个 Get-DeviceIdLocal / 1 个 ssh-config marker

    主菜单:
      [1] PreCheck             — 7 节体检报告
      [2] Install              — 默认 mode=both(server+client)
      [3] VPS 状态 + 同步       — 拉 device list → 重写 ~/.ssh/config + PowerShell alias
      [4] Register 本机到 VPS  — POST /device/register
      [5] Unregister 主机       — 从 VPS 列表挑一台注销
      [6] Uninstall 本机        — 反向操作
      [7] Syncthing 协同       — 装 + 接共享 + long-poller
      [0] Exit

.PARAMETER VpsHost
    VPS 公网 IP(frps + ssh-deploy-api 所在)
.PARAMETER BearerToken
    ssh-deploy-api 的 Bearer token
.PARAMETER FrpToken
    FRPS 双向校验 token
.PARAMETER LocalUser
    本机 Win11 账号(SSH 连入用),默认 WuKong
.PARAMETER FrpSshPort
    frp 转 SSH 端口(默认 6000)
.PARAMETER ServerName
    VPS 注册名(默认 = $env:COMPUTERNAME 小写)
.PARAMETER InstallMode
    'both'(默认)/ 'server' / 'client'
.PARAMETER TokenFile
    密钥文档路径(.env 风格 KEY=VALUE)

.EXAMPLE
    # 拉 + 跑
    $tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/windows/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
#>

[CmdletBinding()]
param(
    [string]$VpsHost,
    [string]$BearerToken,
    [string]$FrpToken,
    [string]$LocalUser = '',
    [int]$FrpSshPort = 0,
    [string]$ServerName,
    [ValidateSet('both', 'server', 'client')]
    [string]$InstallMode = 'both',
    [string]$TokenFile
)

# 启动计时(最先)
$script:startTime = Get-Date

# ─────────────────────────────────────────────────────────────────────
# Module 0 — Constants + Logging
# ─────────────────────────────────────────────────────────────────────
#region Module 0 — Constants + Logging

$script:VERSION = 'v3.0'

# CommitShort: 从 $PSScriptRoot/../.git/HEAD 读 (本地开发) 或 fallback 到 'unknown'
# raw 拉 (无 .git) 时返 'unknown'
$script:CommitShort = 'unknown'
try {
    $gitHead = Join-Path (Split-Path $PSScriptRoot -Parent) '.git\HEAD'
    if (Test-Path $gitHead) {
        $ref = Get-Content $gitHead -ErrorAction Stop | Select-Object -First 1
        if ($ref -match '^ref:\s+refs/heads/(.+)$') {
            $branchRefFile = Join-Path (Split-Path $gitHead -Parent) "refs\heads\$($Matches[1])"
            if (Test-Path $branchRefFile) {
                $hash = (Get-Content $branchRefFile -ErrorAction Stop).Trim()
                if ($hash.Length -ge 7) { $script:CommitShort = $hash.Substring(0, 7) }
            }
        }
        elseif ($ref -match '^[0-9a-f]{7,}') {
            $script:CommitShort = $ref.Substring(0, 7)
        }
    }
} catch { }

$script:DEFAULT_VPS = '8.163.106.31'
$script:DEFAULT_PORT = 6000
$script:DEFAULT_USER = 'WuKong'

$script:FrpcInstallDir = 'C:\frp'
$script:BundledFrpc = Join-Path $PSScriptRoot 'bin\frp\frpc.exe'
$script:RemoteFrpcUrl = 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/frp/frpc.exe'
$script:FrpcMinBytes = 1MB

$script:SshDir = "$env:USERPROFILE\.ssh"
$script:SshCfg = "$script:SshDir\config"
$script:ProfilePath = $PROFILE
$script:SecretsFile = "$script:SshDir\deploy-secrets.md"
$script:OPENSSH_ZIP_NAME = 'OpenSSH-Win64.zip'
$script:OPENSSH_GH_URL = 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/openssh/OpenSSH-Win64.zip'

$script:HttpTimeout = 30           # 默认 API timeout (was 8/15)
$script:HttpTimeoutLongPoll = 60   # /device/changes?wait=30
$script:HttpMaxRetries = 3

# ssh-config / PROFILE 段 markers (单源)
$script:MarkerConfig = "(?ms)# ===== ssh-deploy:.*?# ===== END ssh-deploy =====\r?\n?"
$script:MarkerAlias = "(?ms)# ===== ssh-deploy aliases =====.*?# ===== END ssh-deploy aliases =====\r?\n?"

# ── Logging 分级 ──
function Write-Info {
    param([Parameter(Mandatory, Position = 0)] [string]$Msg)
    Write-Host "[INFO] $Msg" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory, Position = 0)] [string]$Msg)
    Write-Host "[OK]   $Msg" -ForegroundColor Green
}

function Write-Warn {
    param([Parameter(Mandatory, Position = 0)] [string]$Msg)
    Write-Host "[WARN] $Msg" -ForegroundColor Yellow
    if ($script:State) { $script:State.WarnCount++ }
}

function Write-Err {
    param(
        [Parameter(Mandatory, Position = 0)] [string]$Msg,
        [switch]$Critical
    )
    Write-Host "[ERR]  $Msg" -ForegroundColor Red
    if ($script:State) {
        $script:State.LastError = $Msg
        $script:State.LastErrorAt = Get-Date -Format 'o'
    }
    if ($Critical) {
        Write-Host "[FATAL] 致命错误,序列中止" -ForegroundColor Red
        if ($script:State) { $script:State.Fatal = $true }
    }
    return (-not $Critical)
}

function Tern {
    <#
    三元 (PS 5.1 没内建). 用: Tern \$cond 'trueStr' 'falseStr'
    \$C 接受任意值 (\$null / 对象 / bool / 数字). if 自动转 bool.
    #>
    param($C, [string]$T, [string]$F)
    if ($C) { return $T } else { return $F }
}

function Write-Step {
    param([string]$Code, [string]$Name)
    $elapsed = (Get-Date) - $script:startTime
    Write-Host ""
    Write-Host "[$Code] $Name  (累计 $([int]$elapsed.TotalSeconds)s)" -ForegroundColor Cyan
}

function Write-Debug {
    param([Parameter(Mandatory, Position = 0)] [string]$Msg)
    if ($script:State -and $script:State.Verbose) {
        Write-Host "[DBG]  $Msg" -ForegroundColor DarkGray
    }
}

# TLS 1.2 (PS 5.1 默认 TLS 1.0, GitHub raw 拒)
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Defender 排除 (失败不致命)
try {
    Add-MpPreference -ExclusionPath "$env:TEMP" -ErrorAction Stop
    Add-MpPreference -ExclusionPath $script:FrpcInstallDir -ErrorAction Stop
}
catch { Write-Debug "Defender 排除跳过: $($_.Exception.Message)" }

# 管理员 assert
function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Administrator)) {
    Write-Err "需管理员 PowerShell(右键 '终端(管理员)')" -Critical
    exit 1
}

$ErrorActionPreference = 'Stop'

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 7 — State + Init (定义在 Module 0 之后, Logging 之前不要用)
# ─────────────────────────────────────────────────────────────────────
#region Module 7 — State + Init

$script:State = @{
    Version      = $script:VERSION
    VpsHost      = ''
    BearerToken  = ''
    FrpToken     = ''
    LocalUser    = ''
    ServerName   = ''
    FrpcPort     = $script:DEFAULT_PORT
    DeviceId     = $null
    InstallMode  = 'both'
    LastError    = ''
    LastErrorAt  = ''
    LastApiError = ''
    WarnCount    = 0
    Elapsed      = @{}
    Verbose      = $false
    Fatal        = $false
}

function Initialize-State {
    # 从 $param 灌入 + 默认值
    $script:State.VpsHost = if ($VpsHost) { $VpsHost } else { $script:DEFAULT_VPS }
    $script:State.LocalUser = if ($LocalUser) { $LocalUser } else { $script:DEFAULT_USER }
    $script:State.ServerName = if ($ServerName) { $ServerName } else { ($env:COMPUTERNAME).ToLower() }
    $script:State.FrpcPort = if ($FrpSshPort -gt 0) { $FrpSshPort } else { $script:DEFAULT_PORT }
    $script:State.InstallMode = $InstallMode

    # 无显式 param 时 prompt 主人确认/改写 server name + frp remote port
    if (-not $ServerName -and -not $FrpSshPort -and $MyInvocation.ExpectingInput) {
        Write-Host ""
        Write-Host "  === 主机标识 / 端口 ===" -ForegroundColor Cyan
        $defaultName = $script:State.ServerName
        $input = Read-Host "  server name (默认 $defaultName,直接回车接受)"
        if ($input) { $script:State.ServerName = $input.ToLower() }
        $defaultPort = $script:State.FrpcPort
        $inputPort = Read-Host "  frp remote port (默认 $defaultPort,直接回车接受)"
        $parsedPort = 0
        if ($inputPort -and [int]::TryParse($inputPort, [ref]$parsedPort) -and $parsedPort -gt 0) {
            $script:State.FrpcPort = $parsedPort
        }
        Write-Host ""
    }

    # Token: param > secrets file > 首次 prompt
    if ($BearerToken) {
        $script:State.BearerToken = $BearerToken
    }
    else {
        $tok = Get-TokenFromFile -FilePath $script:SecretsFile -Key 'BEARER_TOKEN'
        if ($tok) {
            $script:State.BearerToken = $tok
            Write-Debug "从 secrets file 读 BEARER_TOKEN"
        }
    }

    if ($FrpToken) {
        $script:State.FrpToken = $FrpToken
    }
    else {
        $tok = Get-TokenFromFile -FilePath $script:SecretsFile -Key 'FRP_TOKEN'
        if ($tok) { $script:State.FrpToken = $tok }
    }
}

function Initialize-TokenCache {
    param([string]$SourcePath)
    if (-not $SourcePath -or -not (Test-Path $SourcePath)) {
        Write-Err "-TokenFile '$SourcePath' 不存在" -Critical
        return $false
    }
    if (-not (Test-Path $script:SshDir)) {
        New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null
    }
    try {
        Copy-Item -Path $SourcePath -Destination $script:SecretsFile -Force -ErrorAction Stop
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        icacls $script:SecretsFile /inheritance:r /grant:r "${me}:(R,W)" "SYSTEM:(R)" 2>&1 | Out-Null
        Write-Ok "token 文档已复制到: $script:SecretsFile"
        Write-Info "  (ACL 限当前用户 R/W + SYSTEM R)"
        return $true
    }
    catch {
        Write-Err "复制 token 文档失败: $($_.Exception.Message)" -Critical
        return $false
    }
}

# ── ~/.ssh ACL helper — 解锁读 / 写 (OpenSSH 装时收紧 ACL, 当前 admin 默认无 R/W) ──
function Unlock-SshFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $true }
    $ok = $true
    try { Set-ItemProperty -Path $Path -Name IsReadOnly -Value $false -ErrorAction Stop } catch {
        Write-Warn "  清 IsReadOnly 失败: $($_.Exception.Message)"
        $ok = $false
    }
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try { icacls $Path /grant:r "${me}:(M)" 2>&1 | Out-Null } catch {
        Write-Warn "  icacls grant 失败: $($_.Exception.Message)"
        $ok = $false
    }
    return $ok
}

function Read-SshConfig {
    <#
    返 hashtable: @{ ok=$true; content=''; status='missing'|'ok'|'unreadable'; err='' }
      missing    → 文件不存在, content='', ok=$true (允许)
      ok         → 读取成功, content=raw, ok=$true
      unreadable → 文件存在但读失败 (锁/ACL/AV), content=$null, ok=$false
                  调用方必须 bail 不能当作空文件覆写 (会清掉用户配置)
    #>
    if (-not (Test-Path $script:SshCfg)) {
        return @{ ok = $true; content = ''; status = 'missing'; err = '' }
    }
    $unlockOk = Unlock-SshFile $script:SshCfg
    if (-not $unlockOk) {
        return @{ ok = $false; content = $null; status = 'unlock-failed'; err = 'ACL 解锁失败' }
    }
    try {
        $raw = Get-Content $script:SshCfg -Raw -ErrorAction Stop
        return @{ ok = $true; content = $raw; status = 'ok'; err = '' }
    }
    catch {
        Write-Warn "读 ~/.ssh/config 失败: $($_.Exception.Message)"
        return @{ ok = $false; content = $null; status = 'unreadable'; err = $_.Exception.Message }
    }
}

function Write-SshConfig {
    <#
    返 [bool]: 写成功 true, 失败 false
    失败时输出 Write-Warn (含原因)
    #>
    param([string]$Content)
    $unlockOk = Unlock-SshFile $script:SshCfg
    if (-not $unlockOk) {
        Write-Warn "写 ~/.ssh/config 跳过: ACL 解锁失败"
        return $false
    }
    try {
        [System.IO.File]::WriteAllText($script:SshCfg, $Content, [System.Text.UTF8Encoding]::new($false))
        return $true
    }
    catch {
        Write-Warn "写 ~/.ssh/config 失败: $($_.Exception.Message)"
        return $false
    }
}

function Get-TokenFromFile {
    param(
        [string]$FilePath,
        [Parameter(Mandatory)][string]$Key
    )
    if (-not $FilePath -or -not (Test-Path $FilePath)) { return $null }
    try {
        $lines = Get-Content $FilePath -ErrorAction Stop
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed.StartsWith('#') -or -not $trimmed) { continue }
            if ($trimmed -match "^$([regex]::Escape($Key))=(.+)$") {
                $val = $Matches[1].Trim() -replace '^"', '' -replace '"$', '' -replace "^'", '' -replace "'$", ''
                return $val
            }
        }
    }
    catch {
        Write-Warn "读 token 文件失败: $($_.Exception.Message)"
    }
    return $null
}

function Resolve-TokenFile {
    <#
    三态:
      1. 显式 -TokenFile → 若 ≠ 默认 → 复制到默认 + icacls;否则直接用
      2. 无 -TokenFile + 默认位置有文件 → 自动用默认
      3. 无 -TokenFile + 默认位置无文件 → 首次,prompt 问主人 → 复制
    #>
    if ($TokenFile) {
        if ($TokenFile -ne $script:SecretsFile) {
            return (Initialize-TokenCache -SourcePath $TokenFile)
        }
        return $true
    }
    elseif (Test-Path $script:SecretsFile) {
        Write-Info "从默认位置读 token: $script:SecretsFile"
        return $true
    }
    else {
        Write-Warn "未找到默认 token 文档 ($script:SecretsFile)"
        $provided = Read-Host "请提供密钥文档完整路径"
        if (-not $provided) {
            Write-Err "未提供 token 文档,退出" -Critical
            return $false
        }
        return (Initialize-TokenCache -SourcePath $provided)
    }
}

# 启动时跑
if (-not (Resolve-TokenFile)) { exit 1 }
Initialize-State

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 3 — Network (HTTP + Retry + frpc 3-tier)
# ─────────────────────────────────────────────────────────────────────
#region Module 3 — Network

function Get-ApiBase {
    param([string]$Path)
    return "http://$($script:State.VpsHost):8081$Path"
}

function Invoke-VpsApi {
    <#
    .SYNOPSIS
        统一 HTTP 入口. 3× retry + 指数 backoff. 4xx 不 retry, 5xx/timeout retry.
    .PARAMETER LongPoll
        /device/changes?wait=30 → 60s timeout
    #>
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        [hashtable]$Body,
        [switch]$LongPoll,
        [string]$DeviceToken
    )

    $timeout = if ($LongPoll) { $script:HttpTimeoutLongPoll } else { $script:HttpTimeout }
    $url = Get-ApiBase $Path
    # 默认 Bearer (admin). DeviceToken 传了就走 X-Device-Token (用于 deregister).
    $headers = @{ Authorization = "Bearer $($script:State.BearerToken)" }
    if ($DeviceToken) {
        $headers['X-Device-Token'] = $DeviceToken
        $headers.Remove('Authorization')
    }

    $attempt = 0
    while ($attempt -lt $script:HttpMaxRetries) {
        $attempt++
        try {
            $args = @{
                Uri         = $url
                Method      = $Method
                Headers     = $headers
                TimeoutSec  = $timeout
                ErrorAction = 'Stop'
            }
            if ($Body) {
                $args.Body = ($Body | ConvertTo-Json -Compress -Depth 10)
                $args.ContentType = 'application/json'
            }
            $resp = Invoke-RestMethod @args
            return $resp
        }
        catch {
            $err = $_.Exception.Message
            $code = $null
            if ($_.Exception.Response) {
                try { $code = [int]$_.Exception.Response.StatusCode } catch {}
            }

            # 4xx 不 retry (客户端错, retry 无意义)
            if ($code -and $code -ge 400 -and $code -lt 500) {
                $script:State.LastApiError = "$code $err"
                Write-Err "API $Method $Path 4xx ($code): $err"
                return $null
            }

            $wait = [Math]::Pow(2, $attempt)   # 1, 2, 4
            if ($attempt -lt $script:HttpMaxRetries) {
                Write-Warn "API $Method $Path 第 $attempt/$($script:HttpMaxRetries) 次失败: $err — 等 ${wait}s 重试"
                Start-Sleep $wait
            }
            $script:State.LastApiError = $err
        }
    }
    Write-Err "API $Method $Path 连试 $script:HttpMaxRetries 次都失败: $($script:State.LastApiError)"
    return $null
}

function Get-DeviceIdLocal {
    <#
    单一源, 替 v2 三个副本 (ssh-deploy.ps1 L244-249 + L1471-1479 + poller L31-40)
    优先读 Syncthing config.xml; 失败 null.
    #>
    $syncthingCfg = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
    if (-not (Test-Path $syncthingCfg)) { return $null }
    try {
        $x = [xml](Get-Content $syncthingCfg -Raw)
        if ($x.configuration.device.id) { return $x.configuration.device.id }
        if ($x.syncthing.device.id) { return $x.syncthing.device.id }
    }
    catch {
        Write-Debug "config.xml 解析失败: $($_.Exception.Message)"
    }
    return $null
}

function Get-FrpcExe {
    <#
    3-tier:
      1. Bundled (仓 bin/frp/frpc.exe)
      2. Installed (C:\frp\frpc.exe)
      3. Network (raw GitHub + retry 3× 30s)
      4. Fallback: 写 setup-frpc-bg-task.bat + 致命错
    .OUTPUTS
      @{ Path, Source, Note } | $null
    #>
    $installed = Join-Path $script:FrpcInstallDir 'frpc.exe'

    # Tier 1: bundled
    if ((Test-Path $script:BundledFrpc) -and (Get-Item $script:BundledFrpc).Length -gt $script:FrpcMinBytes) {
        return @{ Path = (Resolve-Path $script:BundledFrpc).Path; Source = 'bundled'; Note = '仓内 bin/frp/frpc.exe' }
    }
    Write-Debug "bundled frpc 不在或太小: $script:BundledFrpc"

    # Tier 2: installed
    if ((Test-Path $installed) -and (Get-Item $installed).Length -gt $script:FrpcMinBytes) {
        return @{ Path = $installed; Source = 'installed'; Note = 'C:\frp\frpc.exe' }
    }

    # Tier 3: network
    $tmp = Join-Path $env:TEMP 'frpc.exe'
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    for ($i = 1; $i -le $script:HttpMaxRetries; $i++) {
        try {
            Write-Info "frpc 下载 第 $i/$($script:HttpMaxRetries) 次 (30s timeout)..."
            Invoke-WebRequest -Uri $script:RemoteFrpcUrl -OutFile $tmp -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
            if ((Test-Path $tmp) -and (Get-Item $tmp).Length -gt $script:FrpcMinBytes) {
                return @{ Path = $tmp; Source = 'downloaded'; Note = "搬去 $installed" }
            }
            Write-Warn "下载文件太小 (size=$((Get-Item $tmp).Length 2>$null)) — 重试"
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
        catch {
            $wait = [Math]::Pow(2, $i)
            Write-Warn "frpc 下载失败: $($_.Exception.Message) — 等 ${wait}s 重试"
            if ($i -lt $script:HttpMaxRetries) { Start-Sleep $wait }
        }
    }

    # Tier 4: fallback .bat
    $bat = Join-Path $script:FrpcInstallDir 'setup-frpc-bg-task.bat'
    Write-FallbackFrpcBat -Path $bat
    Write-Err "frpc.exe 拿不到 (bundled/instanced/网络都失败). 已写 fallback $bat — 右键管理员跑一次再重试" -Critical
    return $null
}

function Write-FallbackFrpcBat {
    <#
    写一个管理员 .bat — 注册 frpc-bg 计划任务 + 启动一次.
    给 schtasks /Create 因 /RU SYSTEM 需管理员时使用.
    #>
    param([string]$Path)
    $content = @'
@echo off
chcp 65001 >nul
echo === 检查管理员 ===
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [ERROR] 必须以管理员身份运行(右键 - 以管理员身份运行)
    pause
    exit /b 1
)
echo === 删残留 ===
schtasks /Delete /TN "frpc-bg" /F >nul 2>&1
echo === 注册 ===
schtasks /Create /TN "frpc-bg" /TR "C:\frp\frpc.exe -c C:\frp\frpc.toml" /SC ONSTART /DELAY 0000:30 /RU SYSTEM /RL HIGHEST /F
if %errorlevel% neq 0 ( echo [ERROR] schtasks /Create 失败 && pause && exit /b 1 )
echo === 重启策略 (失败 1min 重启,最多 999 次) ===
schtasks /Set /TN "frpc-bg" /RESTART 999 /RESTARTMIN 01 /TIME 00:00:00 /ET 23:59:59
echo === 立刻跑一次 ===
schtasks /Run /TN "frpc-bg"
echo === 验证 ===
schtasks /Query /TN "frpc-bg" /V /FO LIST
echo === 完成 ===
pause
'@
    if (-not (Test-Path $script:FrpcInstallDir)) {
        New-Item -ItemType Directory -Path $script:FrpcInstallDir -Force | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

function Test-NetworkEgress {
    <#
    测到 VPS :8081 可达 (TCP connect, 5s timeout).
    不用 Test-NetConnection -TimeoutSec (PS 5.1 cmdlet 早期版本无此参数).
    返 [bool]. 顺手打 status message.
    #>
    $isOpen = $false
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $iar = $tcp.BeginConnect($script:State.VpsHost, 8081, $null, $null)
        $ok = $iar.AsyncWaitHandle.WaitOne(5000, $false)
        if ($ok) {
            $tcp.EndConnect($iar)
            $isOpen = $true
        }
        $tcp.Close()
    } catch {
        $isOpen = $false
    }

    if ($isOpen) {
        Write-Host "端口 8081 开放，服务正常。"
    }
    else {
        Write-Host "端口 8081 不可达，请检查防火墙或服务状态。"
    }

    return $isOpen
}

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 1 — PreFlight (PreCheck, pure read)
# ─────────────────────────────────────────────────────────────────────
#region Module 1 — PreFlight

function Test-FrpcHealth {
    <#
    4 态检测: 任务 / exe / toml / 进程. 全用 if/else, 不用 Tern.
    .OUTPUTS
        @{ Task, Exe, ExePath, Toml, Process, ProcId, Source, Note }
    #>
    $exePath = Join-Path $script:FrpcInstallDir 'frpc.exe'
    $tomlPath = Join-Path $script:FrpcInstallDir 'frpc.toml'

    # Task
    $taskObj = Get-ScheduledTask 'frpc-bg' -ErrorAction SilentlyContinue
    $hasTask = [bool]($null -ne $taskObj)

    # Exe (size check)
    $hasExe = $false
    $exe = $null
    if (Test-Path $exePath) {
        $size = (Get-Item $exePath).Length
        if ($size -gt $script:FrpcMinBytes) {
            $hasExe = $true
            $exe = $exePath
        }
    }

    # Toml
    $hasToml = Test-Path $tomlPath
    if ($hasToml) { $hasToml = $true } else { $hasToml = $false }

    # Process
    $procObj = Get-Process -Name frpc -ErrorAction SilentlyContinue
    $hasProc = [bool]($null -ne $procObj)
    $procId = if ($null -ne $procObj) { $procObj.Id } else { $null }

    # Source
    $source = 'none'
    if ($hasExe) {
        if ($exe -like '*Temp*frpc.exe') {
            $source = 'downloaded-temp'
        }
        else {
            $source = 'installed'
        }
    }

    return @{
        Task    = $hasTask
        Exe     = $hasExe
        ExePath = $exe
        Toml    = $hasToml
        Process = $hasProc
        ProcId  = $procId
        Source  = $source
        Note    = $null
    }
}

function Test-ReverseSshTunnel {
    <#
    3s ssh smoke. PreCheck 用.
    .OUTPUTS
        [bool] $true = 通
    #>
    param([string]$HostAlias)
    if (-not $HostAlias) { return $false }
    try {
        $out = ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no $HostAlias 'echo SSH_TUNNEL_OK' 2>&1
        return ($LASTEXITCODE -eq 0 -and ($out -join ' ') -match 'SSH_TUNNEL_OK')
    }
    catch {
        return $false
    }
}

function Get-VpsDeviceList {
    <#
    返 devices list (含 fallback Bearer 解析). 走 Module 3.
    .OUTPUTS
        @{} | $null
    #>
    $resp = Invoke-VpsApi -Method GET -Path '/device/list'
    if ($resp) { return $resp }
    return $null
}

function Invoke-PreCheck {
    <#
    7 节 PreCheck 报告: 管理员 / OS / 账号 / 网络 / 环境 / 端口 / e2e smoke
    pure read, 不改任何东西.
    #>
    Write-Info "========== PreCheck =========="

    # 1. 管理员 / OS
    $isAdmin = Test-Administrator
    Write-Host ("  $(Tern $isAdmin '✅' '❌') 管理员")
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Write-Host "  OS: $($os.Caption) Build $($os.BuildNumber)"
    }
    catch { Write-Host "  OS: (查不到)" }

    # 2. 账号 (密码检查已删除 — 主人 2026-08-04 要求)
    $user = $script:State.LocalUser
    try {
        $u = Get-LocalUser -Name $user -ErrorAction Stop
        Write-Host "  账号 ${user}: ✅ 存在"
    }
    catch {
        Write-Host "  账号 ${user}: (不是本地用户,可能 AD)"
    }

    # 3. 网络 egress 到 VPS
    $tcpOk = Test-NetworkEgress
    Write-Host ("  network → $($script:State.VpsHost):8081: $(Tern $tcpOk '✅ TCP 通' '❌ 不通')")
    # VPS API 检查 — 包 try/catch, 失败不阻断 PreCheck
    if ($tcpOk) {
        try {
            $list = Get-VpsDeviceList
            if ($list) {
                $n = if ($list.devices) { $list.devices.Count } else { 0 }
                Write-Host "  VPS API: ✅ GET /device/list (devices=$n)"
            }
            else {
                Write-Host "  VPS API: ❌ /device/list 失败 — $($script:State.LastApiError)"
            }
        } catch {
            Write-Host "  VPS API: ❌ 异常 — $($_.Exception.Message)"
        }
    }

    # 4. 环境: sshd / ssh.exe / frpc / frpc.toml / frpc-bg / frpc 进程
    Write-Host ""
    Write-Info "  环境:"
    $sshdExe = "$env:ProgramFiles\OpenSSH\sshd.exe"
    Write-Host ("    sshd.exe:    $(Tern (Test-Path $sshdExe) '✅ 已装' '❌ 未装')")
    $sshExe = "$env:ProgramFiles\OpenSSH\ssh.exe"
    Write-Host ("    ssh.exe:     $(Tern (Test-Path $sshExe) '✅ 已装' '❌ 未装')")
    $health = Test-FrpcHealth
    if ($health.Exe) {
        Write-Host ("    frpc.exe:    ✅ $($health.ExePath) [$($health.Source)]")
    } else {
        Write-Host "    frpc.exe:    ❌ 未装"
    }
    if ($health.Toml) {
        Write-Host "    frpc.toml:   ✅ 已配置"
    } else {
        Write-Host "    frpc.toml:   ❌ 未写"
    }
    if ($health.Task) {
        Write-Host "    frpc-bg:     ✅ Ready"
    } else {
        Write-Host "    frpc-bg:     ❌ 未注册"
    }
    if ($health.Process) {
        Write-Host ("    frpc 进程:   ✅ PID $($health.ProcId)")
    } else {
        Write-Host "    frpc 进程:   ❌ 未跑"
    }

    # 5. 端口 / 防火墙
    Write-Host ""
    Write-Info "  端口 / 防火墙:"
    $conn22 = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    Write-Host ("    :22 LISTEN:        $(Tern $conn22 '✅' '❌ 未监听')")
    $fw = Get-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    Write-Host (" 防火墙 :22 放行: $(Tern ($null -ne $fw) '✅' '❌ 未加')")

    # 6. 痕迹 (ssh-deploy 关心的)
    Write-Host ""
    Write-Info "  痕迹:"
    $oldFrp = 'C:\Tools\frp'
    Write-Host ("    C:\Tools\frp (老): $(Tern (Test-Path $oldFrp) '⚠  存在,要清' '✅ 无')")
    $cfgRead = Read-SshConfig
    if (-not $cfgRead.ok) {
        Write-Host "    ~/.ssh/config 段: ❌ 读失败 ($($cfgRead.status): $($cfgRead.err)) — 跳"
    } else {
        $cfgRaw = $cfgRead.content
        Write-Host ("    ~/.ssh/config 段: $(Tern ($cfgRaw -match '# ===== ssh-deploy:') '⚠  存在,要清' '✅ 无')")
    }
    $oldTask = Get-ScheduledTask 'frpc-autostart' -ErrorAction SilentlyContinue
    Write-Host ("    frpc-autostart (老任务): $(Tern $oldTask '⚠  存在,要清' '✅ 无')")

    # 7. 端到端 smoke
    Write-Host ""
    Write-Info "  端到端 SSH smoke:"
    $first = $null
    $cfgSafe = if ($cfgRaw) { $cfgRaw } else { '' }
    foreach ($m in [regex]::Matches($cfgSafe, 'Host\s+(wpc-[\w-]+)')) {
        $first = $m.Groups[1].Value
        break
    }
    if ($first) {
        $ok = Test-ReverseSshTunnel -HostAlias $first
        if ($ok) {
            Write-Host "    ssh ${first}: ✅ 通 (反向 SSH 链路活)"
        }
        else {
            Write-Host "    ssh ${first}: ❌ 失败"
            Write-Host "      常见: frpc 死 / frpc-bg 没起 / VPS 端口 6000 not LISTEN / 阿里云 SG 没放"
        }
    }
    else {
        Write-Host "    (无 wpc-* Host,跳)"
    }

    # 8. 致命错误快照
    if ($script:State.LastError) {
        Write-Host ""
        Write-Host "  ⚠ 上次错误: $($script:State.LastError) (at $($script:State.LastErrorAt))"
    }
    Write-Host "=========================================" -ForegroundColor Cyan
}

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 2 — Install (表驱动, S1-S5 + C1-C3)
# ─────────────────────────────────────────────────────────────────────
#region Module 2 — Install

# 单一源: 8 步定义
$script:InstallSteps = @(
    @{ Code = 'S1'; Fn = 'Install-OpenSSHServer'; Needs = @('Admin'); Critical = $true; SkipIn = 'client' }
    @{ Code = 'S2'; Fn = 'Set-SshdConfig'; Needs = @('Admin'); Critical = $true; SkipIn = 'client' }
    @{ Code = 'S3'; Fn = 'Add-FirewallRule22'; Needs = @('Admin'); Critical = $true; SkipIn = 'client' }
    @{ Code = 'S4'; Fn = 'Install-Frpc'; Needs = @('Admin', 'FrpToken'); Critical = $false; SkipIn = 'client' }
    @{ Code = 'S5'; Fn = 'Test-AccountAndRestartSshd'; Needs = @('Admin'); Critical = $true; SkipIn = 'client' }
    @{ Code = 'C1'; Fn = 'Install-OpenSSHClient'; Needs = @(); Critical = $true; SkipIn = 'server' }
    @{ Code = 'C2'; Fn = 'Sync-SshConfigFromVps'; Needs = @('Bearer'); Critical = $false; SkipIn = 'server' }
    @{ Code = 'C3'; Fn = 'Add-PowerShellAliases'; Needs = @(); Critical = $false; SkipIn = 'server' }
)

function Get-InstallStep {
    param([string]$Mode, [string]$Code)
    foreach ($s in $script:InstallSteps) {
        if ($s.Code -eq $Code) { return $s }
        if ($Mode -eq 'both' -and $s.SkipIn -eq 'server,client') { continue }
    }
    return $null
}

function Test-InstallNeeds {
    param($Step)
    if ($Step.Needs -contains 'Admin' -and -not (Test-Administrator)) {
        Write-Err "$($Step.Code) 需管理员" -Critical
        return $false
    }
    if ($Step.Needs -contains 'FrpToken' -and -not $script:State.FrpToken) {
        Write-Warn "$($Step.Code) FrpToken 未设, 跳过"
        return $false
    }
    if ($Step.Needs -contains 'Bearer' -and -not $script:State.BearerToken) {
        Write-Warn "$($Step.Code) BearerToken 未设, 跳过"
        return $false
    }
    return $true
}

function Invoke-Install {
    <#
    .SYNOPSIS
        表驱动跑 8 步. Critical 失败即停, 非 Critical 继续.
    .PARAMETER Mode
        'both' / 'server' / 'client'
    #>
    param([string]$Mode = $script:State.InstallMode)

    Write-Info "========== Install (mode=$Mode) =========="

    # 启动 PreCheck (干跑)
    Invoke-PreCheck
    if ($script:State.Fatal) {
        Write-Err "PreCheck 致命错, 退出 Install" -Critical
        return @{ ok = $false; failed = 'PreCheck' }
    }

    foreach ($step in $script:InstallSteps) {
        # 跳过 SkipIn
        if ($Mode -eq 'server' -and $step.SkipIn -eq 'server') { continue }
        if ($Mode -eq 'client' -and $step.SkipIn -eq 'client') { continue }

        Write-Step $step.Code $step.Fn
        $stepStart = Get-Date

        if (-not (Test-InstallNeeds -Step $step)) {
            $script:State.Elapsed[$step.Code] = ((Get-Date) - $stepStart).TotalSeconds
            if ($step.Critical) {
                Write-Err "Install 序列中止 @ $($step.Code)" -Critical
                return @{ ok = $false; failed = $step.Code }
            }
            continue
        }

        try {
            $r = & $step.Fn
            $script:State.Elapsed[$step.Code] = ((Get-Date) - $stepStart).TotalSeconds
            if ($r -is [hashtable] -and -not $r.ok) {
                if ($step.Critical) {
                    Write-Err "Install 序列中止 @ $($step.Code)" -Critical
                    return @{ ok = $false; failed = $step.Code; detail = $r.msg }
                }
            }
            else {
                Write-Ok "$($step.Code) ok"
            }
        }
        catch {
            $script:State.Elapsed[$step.Code] = ((Get-Date) - $stepStart).TotalSeconds
            Write-Err "$($step.Code) 抛错: $($_.Exception.Message)" -Critical:$step.Critical
            if ($step.Critical) {
                return @{ ok = $false; failed = $step.Code; detail = $_.Exception.Message }
            }
        }

        if ($script:State.Fatal) {
            return @{ ok = $false; failed = 'fatal-flag' }
        }
    }

    Write-Info "========== Install 完成 ($Mode) =========="
    return @{ ok = $true }
}

# ── Step S1: OpenSSH Server ──
function Install-OpenSSHServer {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($cap.State -eq 'Installed') {
        Write-Info "  OpenSSH Server 已装, 跳过"
    }
    else {
        try {
            Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0 -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warn "  Add-WindowsCapability 失败: $($_.Exception.Message) — 试离线包"
            $workDir = Join-Path $env:TEMP 'ssh-deploy-openssh'
            $zip = Get-OpenSSHZip -WorkDir $workDir
            if (-not $zip) {
                return @{ ok = $false; msg = '离线包也拿不到' }
            }
            $expanded = Expand-OpenSSHZip -ZipPath $zip.path -ExpandRoot $workDir
            # 走 Setup 脚本
            & "$expanded\install-sshd.ps1" 2>&1 | Out-Null
        }
    }
    Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    Write-Info "  sshd 服务: $(Get-Service sshd -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Status)"
    return @{ ok = $true }
}

# ── Step S2: sshd_config ──
function Set-SshdConfig {
    $src = "$env:ProgramData\ssh\sshd_config"
    $bck = "$src.bak"
    if (-not (Test-Path $src)) {
        Write-Warn "  sshd_config 不存在: $src"
        return @{ ok = $false; msg = 'sshd_config 不存在' }
    }
    if (-not (Test-Path $bck)) { Copy-Item $src $bck -Force }

    # 替换关键配置
    $content = Get-Content $src -Raw
    $content = $content -replace '(?m)^#?PasswordAuthentication\s+.*$', 'PasswordAuthentication yes'
    $content = $content -replace '(?m)^#?PubkeyAuthentication\s+.*$', 'PubkeyAuthentication yes'
    $content = $content -replace '(?m)^#?PermitRootLogin\s+.*$', 'PermitRootLogin no'

    # 写文件前先清只读 + grant write (ProgramData\ssh 默认 ACL 可能阻 admin 写)
    try { Set-ItemProperty -Path $src -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try { icacls $src /grant:r "${me}:(M)" 2>&1 | Out-Null } catch {}

    [System.IO.File]::WriteAllText($src, $content, [System.Text.UTF8Encoding]::new($false))
    Write-Info "  sshd_config 已更新 (Password/Pubkey yes, PermitRootLogin no)"
    return @{ ok = $true }
}

# ── Step S3: 防火墙 :22 ──
function Add-FirewallRule22 {
    $existing = Get-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Info "  防火墙规则已存在"
    }
    else {
        New-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP' -Direction Inbound -Protocol TCP -LocalPort 22 -Action Allow -ErrorAction Stop | Out-Null
        Write-Info "  防火墙 :22 放行"
    }
    return @{ ok = $true }
}

# ── Step S4: frpc.exe + 自启 ──
function Install-Frpc {
    $health = Test-FrpcHealth

    # 4 态: 都 OK → 跳
    if ($health.Task -and $health.Exe -and $health.Toml -and $health.Process) {
        Write-Info "  frpc 健康 (task+exe+toml+进程), 跳过"
        return @{ ok = $true }
    }
    Write-Warn "  frpc 不健康: task=$($health.Task) exe=$($health.Exe) toml=$($health.Toml) 进程=$($health.Process)"

    # 杀残留
    if ($health.Process) {
        Get-Process -Name frpc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep 2
    }

    # 建目录
    if (-not (Test-Path $script:FrpcInstallDir)) {
        New-Item -ItemType Directory -Path $script:FrpcInstallDir -Force | Out-Null
        Write-Info "  建目录 $($script:FrpcInstallDir)"
    }

    # 拿 frpc.exe (3-tier)
    $exe = Get-FrpcExe
    if (-not $exe) {
        return @{ ok = $false; msg = 'frpc.exe 拿不到' }
    }
    Write-Info "  ✅ 拿 frpc.exe [tier=$($exe.Source)] $exe.Path"

    # 装到 C:\frp
    if ($exe.Source -ne 'installed') {
        $dest = Join-Path $script:FrpcInstallDir 'frpc.exe'
        Copy-Item $exe.Path $dest -Force -ErrorAction Stop
        Write-Info "  装到 $dest"
    }

    # 写 frpc.toml
    $toml = @"
serverAddr = "$($script:State.VpsHost)"
serverPort = 7000
auth.token = "$($script:State.FrpToken)"

transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30

# 本机反向 SSH 转发
[[proxies]]
name = "$($script:State.ServerName)-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $($script:State.FrpcPort)
transport.useCompression = true
"@
    $tomlPath = Join-Path $script:FrpcInstallDir 'frpc.toml'
    [System.IO.File]::WriteAllText($tomlPath, $toml, [System.Text.UTF8Encoding]::new($false))
    Write-Info "  frpc.toml 已写 (remotePort=$($script:State.FrpcPort))"

    # 注册 frpc-bg 计划任务
    $task = Get-ScheduledTask 'frpc-bg' -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName 'frpc-bg' -Confirm:$false }
    $xml = @'
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Author>wukong0908</Author>
    <URI>\frpc-bg</URI>
  </RegistrationInfo>
  <Triggers>
    <BootTrigger>
      <Enabled>true</Enabled>
    </BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>5</Priority>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>999</Count>
    </RestartOnFailure>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>C:\frp\frpc.exe</Command>
      <Arguments>-c C:\frp\frpc.toml</Arguments>
      <WorkingDirectory>C:\frp</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
'@

    $tmpXml = Join-Path $env:TEMP 'frpc-bg.xml'
    [System.IO.File]::WriteAllText($tmpXml, $xml, [System.Text.UTF8Encoding]::new($false))
    $regErr = $null
    try {
        Register-ScheduledTask -TaskName 'frpc-bg' -Xml (Get-Content $tmpXml -Raw) -Force -ErrorAction Stop | Out-Null
    }
    catch {
        $regErr = $_.Exception.Message
    }
    Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
    if ($regErr) {
        Write-Warn "  Register-ScheduledTask 失败: $regErr"
        Write-Warn "  极可能 shell 非管理员 — 写 fallback .bat"
        Write-FallbackFrpcBat -Path (Join-Path $script:FrpcInstallDir 'setup-frpc-bg-task.bat')
        Write-Info "  不阻断主流程 (frpc 进程能起, 没守护), 右键管理员跑 .bat 后重跑"
    }
    else {
        Write-Info "  frpc-bg 已注册"
    }

    # 立即跑一次
    schtasks /Run /TN 'frpc-bg' 2>&1 | Out-Null
    Start-Sleep 6
    $frpcProc = Get-Process -Name frpc -ErrorAction SilentlyContinue
    if ($frpcProc) {
        Write-Ok "  frpc 启了 (PID $($frpcProc.Id))"
    }
    else {
        Write-Warn "  frpc 暂未起, 看 TaskScheduler Operational 日志"
    }
    return @{ ok = $true }
}

# ── Step S5: 账号 + 密码 + sshd restart ──
function Test-AccountAndRestartSshd {
    $user = $script:State.LocalUser

    # 检查账号存在 (密码检查已删除 — 主人 2026-08-04 要求)
    try {
        $u = Get-LocalUser -Name $user -ErrorAction Stop
        Write-Info "  账号 $user ✅"
    }
    catch {
        Write-Err "账号 $user 不存在" -Critical
        return @{ ok = $false; msg = '账号不存在' }
    }

    # sshd 重启
    Restart-Service sshd -Force -ErrorAction Stop
    Write-Info "  sshd 已重启"
    return @{ ok = $true }
}

# ── Step C1: OpenSSH Client ──
function Install-OpenSSHClient {
    $cap = Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 -ErrorAction SilentlyContinue
    if ($cap.State -eq 'Installed') {
        Write-Info "  OpenSSH Client 已装"
        return @{ ok = $true }
    }
    try {
        Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Warn "  Add-WindowsCapability 失败: $($_.Exception.Message) — 试离线包"
        $workDir = Join-Path $env:TEMP 'ssh-deploy-openssh'
        $zip = Get-OpenSSHZip -WorkDir $workDir
        if (-not $zip) { return @{ ok = $false; msg = '离线包拿不到' } }
        $expanded = Expand-OpenSSHZip -ZipPath $zip.path -ExpandRoot $workDir
        & "$expanded\install-sshl.ps1" 2>&1 | Out-Null
    }
    return @{ ok = $true }
}

# ── Step C2: 同步 VPS device list → ~/.ssh/config ──
function Sync-SshConfigFromVps {
    $list = Get-VpsDeviceList
    if (-not $list) {
        Write-Warn "  /device/list 失败 — 跳过 (看 LastApiError)"
        return @{ ok = $false; msg = 'device list 失败' }
    }
    $devices = $list.devices
    if (-not $devices) { $devices = @() }

    # 写 ~/.ssh/config wpc-* 段
    if (-not (Test-Path $script:SshDir)) { New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null }
    $cfgRead = Read-SshConfig
    if (-not $cfgRead.ok) {
        Write-Warn "  读 ~/.ssh/config 失败 ($($cfgRead.status): $($cfgRead.err)) — 跳过 (防覆盖用户已有 Host)"
        return @{ ok = $false; msg = 'config 读失败' }
    }
    $cfgRaw = $cfgRead.content
    $cfgRaw = [regex]::Replace($cfgRaw, $script:MarkerConfig, '')

    # 校验每个 device 字段齐 (capabilities.sshd.user + .frpc.remote_port)
    foreach ($d in $devices) {
        $name = $d.device_name
        if (-not $name) { Write-Warn "  跳过无 device_name 的设备"; continue }
        $usr = $d.capabilities.sshd.user
        $port = $d.capabilities.frpc.remote_port
        if (-not $usr -or -not $port) {
            Write-Warn "  跳过 $($name): sshd.user='$usr' frpc.remote_port='$port' 缺字段"
            continue
        }
        $newBlock += "Host wpc-$name`n  HostName $($script:State.VpsHost)`n  Port $port`n  User $usr`n  ServerAliveInterval 30`n  ServerAliveCountMax 3`n`n"
    }

    $newBlock += "# ===== END ssh-deploy =====`n`n"
    $cfgRaw = $newBlock + $cfgRaw
    $written = Write-SshConfig $cfgRaw
    if (-not $written) {
        Write-Err "  写 ~/.ssh/config 失败 — 配置未更新" -Critical
        return @{ ok = $false; msg = 'config 写失败' }
    }
    $count = ($devices | Where-Object {
        $_.device_name -and $_.capabilities.sshd.user -and $_.capabilities.frpc.remote_port
    }).Count
    Write-Info "  ~/.ssh/config 写了 $count 个 wpc-* 段"
    return @{ ok = $true; count = $count }
}

# ── Step C3: PowerShell alias wpc-* ──
function Add-PowerShellAliases {
    $list = Get-VpsDeviceList
    if (-not $list) { return @{ ok = $false; msg = 'no list' } }
    $devices = $list.devices
    if (-not $devices) { $devices = @() }

    $profileFile = $script:ProfilePath
    if (-not (Test-Path $profileFile)) { New-Item -ItemType File -Path $profileFile -Force | Out-Null }
    $raw = Get-Content $profileFile -Raw -ErrorAction SilentlyContinue
    if (-not $raw) { $raw = '' }
    $raw = [regex]::Replace($raw, $script:MarkerAlias, '')

    $block = "# ===== ssh-deploy aliases =====`n"
    foreach ($d in $devices) {
        $name = $d.device_name
        $block += "Set-Alias -Name wpc-$name -Value ssh -Force`n"
    }
    $block += "# ===== END ssh-deploy aliases =====`n"
    $raw = $block + "`n" + $raw
    [System.IO.File]::WriteAllText($profileFile, $raw, [System.Text.UTF8Encoding]::new($false))
    Write-Info "  $profileFile 写了 $($devices.Count) 个 alias"
    return @{ ok = $true }
}

# ── helpers (OpenSSH zip) ──
function Get-OpenSSHZip {
    param([string]$WorkDir)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    $localZip = Join-Path $WorkDir $script:OPENSSH_ZIP_NAME
    if (Test-Path $localZip -PathType Leaf) {
        return @{ path = $localZip; source = 'cached' }
    }
    Write-Info "  下载 OpenSSH zip (从 GitHub raw)..."
    try {
        Invoke-WebRequest -Uri $script:OPENSSH_GH_URL -OutFile $localZip -UseBasicParsing -ErrorAction Stop
        return @{ path = $localZip; source = 'github-raw' }
    }
    catch {
        Write-Warn "  OpenSSH 下载失败: $($_.Exception.Message)"
        return $null
    }
}

function Expand-OpenSSHZip {
    param([string]$ZipPath, [string]$ExpandRoot)
    $expandDir = Join-Path $ExpandRoot 'openssh_expand'
    if (Test-Path $expandDir) { Remove-Item $expandDir -Recurse -Force }
    New-Item -ItemType Directory -Path $expandDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zipFull = [System.IO.Path]::GetFullPath($ZipPath)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipFull)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }
            $destPath = Join-Path $expandDir $entry.FullName
            $destDir = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $entryStream = $entry.Open()
            try {
                $fileStream = [System.IO.File]::Create($destPath)
                try { $entryStream.CopyTo($fileStream) } finally { $fileStream.Close() }
            }
            finally { $entryStream.Close() }
        }
    }
    finally { $archive.Dispose() }
    $sub = Get-ChildItem $expandDir -Directory | Where-Object Name -like 'OpenSSH-Win64' | Select-Object -First 1
    if (-not $sub) { throw "zip 内找不到 OpenSSH-Win64 子目录" }
    return $sub.FullName
}

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 4 — Register / Deregister / Sync
# ─────────────────────────────────────────────────────────────────────
#region Module 4 — Register / Deregister

function Register-ThisHost {
    <#
    POST /device/register. 替 v2 2 个 Register (Install 自动 + Register-DeviceToVPS).
    #>
    $deviceId = Get-DeviceIdLocal
    if (-not $deviceId) {
        # 没有 device id 就用 mac-derived 占位 — 走最普通方式
        $deviceId = [guid]::NewGuid().ToString()
        Write-Warn "  没找到 Syncthing device id, 用临时 UUID: $deviceId"
    }

    $body = @{
        device_id    = $deviceId
        device_name  = $script:State.ServerName
        owner        = 'wukong0908'
        capabilities = @{
            sshd      = @{ user = $script:State.LocalUser }
            frpc      = @{ remote_port = $script:State.FrpcPort }
            syncthing = @{ folders = @() }
        }
    }
    $resp = Invoke-VpsApi -Method POST -Path '/device/register' -Body $body
    if ($resp) {
        Write-Ok "  注册成功: $($script:State.ServerName) (port $($script:State.FrpcPort))"
        if ($resp.auth_token) {
            Write-Info "  auth_token: $($resp.auth_token)"
        }
        return @{ ok = $true; token = $resp.auth_token }
    }
    else {
        Write-Err "  注册失败: $($script:State.LastApiError)"
        return @{ ok = $false; msg = $script:State.LastApiError }
    }
}

function Unregister-Host {
    <#
    列 VPS 设备 → 选 → confirm → POST /device/deregister
    #>
    $list = Invoke-VpsApi -Method GET -Path '/device/list'
    if (-not $list -or -not $list.devices) {
        Write-Warn "  没有设备可注销"
        return @{ ok = $false }
    }
    Write-Host "  当前 VPS 设备:"
    for ($i = 0; $i -lt $list.devices.Count; $i++) {
        $d = $list.devices[$i]
        Write-Host "    [$($i+1)] $($d.device_name) (port $($d.capabilities.frpc.remote_port))"
    }
    $pick = Read-Host "  选 [1-$($list.devices.Count)] 或 0 取消"
    $idx = 0
    if (-not [int]::TryParse($pick, [ref]$idx) -or $idx -lt 1 -or $idx -gt $list.devices.Count) {
        Write-Info "  取消"
        return @{ ok = $false }
    }
    $target = $list.devices[$idx - 1]
    $confirm = Read-Host "  确认注销 $($target.device_name)? (yes/no)"
    if ($confirm -ne 'yes') { Write-Info "  取消"; return @{ ok = $false } }

    # auth_token (VPS device-registry 要求). 优先 list 返回;否则 prompt.
    $authToken = $target.auth_token
    if (-not $authToken) {
        Write-Warn "  list 没返回 auth_token — 需要手动输入"
        $authToken = Read-Host "  paste auth_token"
        if (-not $authToken) {
            Write-Err "  没 auth_token, 无法注销"
            return @{ ok = $false }
        }
    }

    $body = @{
        device_id = $target.device_id
    }
    # VPS 要求 deregister 走 X-Device-Token header (auth_token), 不能用 Bearer
    $resp = Invoke-VpsApi -Method POST -Path '/device/deregister' -Body $body -DeviceToken $authToken
    if ($resp) {
        Write-Ok "  已注销 $($target.device_name)"
        return @{ ok = $true }
    }
    else {
        Write-Err "  注销失败: $($script:State.LastApiError)"
        return @{ ok = $false }
    }
}

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 6 — Uninstall
# ─────────────────────────────────────────────────────────────────────
#region Module 6 — Uninstall

function Invoke-Uninstall {
    $confirm = Read-Host "卸载会停 sshd / 杀 frpc / 清 .ssh/config 段 / 注销 VPS. 确认 yes?"
    if ($confirm -ne 'yes') { Write-Info "取消"; return }

    # 1. 注销 VPS (从 list 取 auth_token; 本机 device_id 用 Get-DeviceIdLocal)
    Write-Info "  注销 VPS..."
    $deviceId = Get-DeviceIdLocal
    if ($deviceId) {
        # 从 VPS 列表找本机 auth_token
        $authToken = $null
        $list = Invoke-VpsApi -Method GET -Path '/device/list'
        if ($list -and $list.devices) {
            foreach ($d in $list.devices) {
                if ($d.device_id -eq $deviceId) {
                    $authToken = $d.auth_token
                    break
                }
            }
        }
        if (-not $authToken) {
            Write-Warn "  本机 device_id 没在 VPS 列表里 / 没 auth_token — 跳过 VPS 注销"
        }
        else {
            $body = @{ device_id = $deviceId }
            $null = Invoke-VpsApi -Method POST -Path '/device/deregister' -Body $body -DeviceToken $authToken
        }
    }

    # 2. 杀 frpc + 删任务
    Write-Info "  杀 frpc..."
    Get-Process -Name frpc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $task = Get-ScheduledTask 'frpc-bg' -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName 'frpc-bg' -Confirm:$false }
    $oldTask = Get-ScheduledTask 'frpc-autostart' -ErrorAction SilentlyContinue
    if ($oldTask) { Unregister-ScheduledTask -TaskName 'frpc-autostart' -Confirm:$false }

    # 3. 删 frpc 文件
    if (Test-Path $script:FrpcInstallDir) {
        Remove-Item $script:FrpcInstallDir -Recurse -Force -ErrorAction SilentlyContinue
        Write-Info "  删 $script:FrpcInstallDir"
    }

    # 4. 停 sshd
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    Set-Service sshd -StartupType Disabled -ErrorAction SilentlyContinue

    # 5. 清 ~/.ssh/config ssh-deploy 段
    if (Test-Path $script:SshCfg) {
        $cfgRead = Read-SshConfig
        if ($cfgRead.ok) {
            $raw = [regex]::Replace($cfgRead.content, $script:MarkerConfig, '')
            $null = Write-SshConfig $raw
        }
    }
    # 6. 清 PROFILE alias 段
    if (Test-Path $script:ProfilePath) {
        $raw = Get-Content $script:ProfilePath -Raw
        $raw = [regex]::Replace($raw, $script:MarkerAlias, '')
        [System.IO.File]::WriteAllText($script:ProfilePath, $raw, [System.Text.UTF8Encoding]::new($false))
    }

    # 7. 删 plan 任务
    $poller = Get-ScheduledTask 'ssh-deploy-poller' -ErrorAction SilentlyContinue
    if ($poller) { Unregister-ScheduledTask -TaskName 'ssh-deploy-poller' -Confirm:$false }

    Write-Ok "卸载完成"
}

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 5 — Menu + Dispatch
# ─────────────────────────────────────────────────────────────────────
#region Module 5 — Menu

function Show-Status {
    <#
    合并 v2 [1] Show-Status + [3] Switch. 拉 device list + 显示云端 + 本机 + 同步 config/alias.
    #>
    Write-Info "========== VPS 状态 =========="

    # 云端
    $list = Get-VpsDeviceList
    if ($list) {
        Write-Info "  云端设备:"
        if ($list.devices) {
            foreach ($d in $list.devices) {
                $port = $d.capabilities.frpc.remote_port
                $user = $d.capabilities.sshd.user
                $online = if ($d.online) { 'online' } else { 'offline' }
                Write-Host "    - $($d.device_name) port $port user $user $online"
            }
        }
        else {
            Write-Info "    (空)"
        }
    }
    else {
        Write-Warn "  /device/list 失败: $($script:State.LastApiError)"
    }

    # 本机
    Write-Host ""
    Write-Info "  本机:"
    $h = Test-FrpcHealth
    if ($h.Process) {
        Write-Host ("    frpc:    running PID $($h.ProcId)")
    } else {
        Write-Host "    frpc:    stopped"
    }
    if ($h.Task) {
        Write-Host "    frpc-bg: Ready"
    } else {
        Write-Host "    frpc-bg: 未注册"
    }
    $sshd = Get-Service sshd -ErrorAction SilentlyContinue
    $sshdStatus = if ($null -ne $sshd) { $sshd.Status } else { 'not installed' }
    Write-Host (" sshd: $sshdStatus")
    $conn22 = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    Write-Host ("    :22:     $(Tern $conn22 'LISTEN' 'no')")

    # 同步本地 config + alias
    Write-Host ""
    Write-Info "  同步本地 config / alias..."
    $null = Sync-SshConfigFromVps
    $null = Add-PowerShellAliases
    Write-Ok "  同步完成 (重启 PowerShell 后 alias 生效)"
}

function Show-Menu {
    Write-Host ""
    Write-Host "========== ssh-deploy v$($script:VERSION) ==========" -ForegroundColor Cyan
    Write-Host "  [1] PreCheck              — 7 节体检报告"
    Write-Host "  [2] Install               — 默认 mode=both (server+client)"
    Write-Host "  [3] VPS 状态 + 同步        — 拉 device list → 重写 ~/.ssh/config + alias"
    Write-Host "  [4] Register 本机到 VPS"
    Write-Host "  [5] Unregister 主机       — 从 VPS 列表挑一台"
    Write-Host "  [6] Uninstall 本机"
    Write-Host "  [7] Syncthing 协同        — 装 + 接共享 + long-poller"
    Write-Host "  [0] Exit"
    Write-Host ""
}

function Invoke-MenuLoop {
    do {
        Show-Menu
        $choice = Read-Host "选"
        switch ($choice) {
            '1' { Invoke-PreCheck }
            '2' { Invoke-Install -Mode $script:State.InstallMode }
            '3' { Show-Status }
            '4' { $null = Register-ThisHost }
            '5' { $null = Unregister-Host }
            '6' { Invoke-Uninstall }
            '7' { Write-Info "使用 ssh-deploy-poller.ps1 (单独脚本, 走菜单 [8] 用 Syncthing 入口)" }
            '0' { Write-Ok "bye"; return }
            default { Write-Warn "未知选项: $choice" }
        }
    } while ($true)
}

#endregion

# ─────────────────────────────────────────────────────────────────────
# Entry
# ─────────────────────────────────────────────────────────────────────
#region Entry

# boot banner
Write-Host "ssh-deploy v$($script:VERSION) ($script:CommitShort) starting..." -ForegroundColor DarkGray
$bearerShort = if ($script:State.BearerToken -and $script:State.BearerToken.Length -gt 0) {
    $script:State.BearerToken.Substring(0, [Math]::Min(8, $script:State.BearerToken.Length))
} else { '(none)' }
Write-Host "  VPS: $($script:State.VpsHost)  Mode: $($script:State.InstallMode)  Bearer: $bearerShort..." -ForegroundColor DarkGray

# Tern 自检 — 抓老版本缓存 (param([bool]$C, ...)) 直接爆错
try {
    $null = Tern $null 'a' 'b'
    $null = Tern '' 'a' 'b'
    $null = Tern 0 'a' 'b'
    $null = Tern @() 'a' 'b'
} catch {
    Write-Host "[FATAL] Tern 函数签名错误 — 你跑的是老版本 ($TEMP\ssh-deploy.ps1 缓存)" -ForegroundColor Red
    Write-Host "        修法: Remove-Item '$TEMP\ssh-deploy.ps1' -Force; 重新拉 + 跑" -ForegroundColor Red
    Write-Host "        当前 commit 应为 $script:CommitShort" -ForegroundColor Red
    throw
}

# entry dispatch
if ($MyInvocation.ExpectingInput) {
    # 交互式
    Invoke-MenuLoop
}
else {
    # 无参数非交互: 跑默认 Install (走 menu 类似行为)
    if ($InstallMode -eq 'both' -and -not $VpsHost) {
        Invoke-MenuLoop
    }
    else {
        Invoke-Install -Mode $InstallMode
    }
}

#endregion
