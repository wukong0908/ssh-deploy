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

    v3.8 改动 (2026-08-04):
      - Install 序列 SC S2 S3 S4 S5 R1 SY (7 步, S1+C1 合并 / C2+C3 合并 / R1 提前)
      - bin 离线装 OpenSSH (windows/bin/openssh/OpenSSH-Win64.zip)
      - S2 删 backup / S5 改 non-Critical / PreCheck 加 VPS 设备节
      - 菜单 5 项 (删 Syncthing 协同 + poller 全删)

    v3.10 改动 (2026-08-04):
      - Register-ThisHost 加 host 名 prompt
      - Uninstall 保留 C:\frp\ 文件 (只杀进程 + 删任务)
      - 启动自动 PreCheck, 菜单 4 项 (删 PreCheck 单独跑)

    主菜单:
      [1] Install              — 默认 mode=both, 启动 PreCheck 自动跑 + R1 注册 + SY 同步
      [2] 同步 VPS 设备          — 拉 device list → 写 ~/.ssh/config + PowerShell alias
      [3] Unregister 主机       — 从 VPS 列表挑一台注销
      [4] Uninstall 本机        — 反向操作 (保留 C:\frp\)
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
    保留兼容 (无实际效果, 装就全装)
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
    [ValidateSet('both')]
    [string]$InstallMode = 'both',
    [string]$TokenFile
)

# 启动计时(最先)
$script:startTime = Get-Date

# ─────────────────────────────────────────────────────────────────────
# Module 0 — Constants + Logging
# ─────────────────────────────────────────────────────────────────────
#region Module 0 — Constants + Logging

$script:VERSION = 'v3.18'

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
$script:DEFAULT_USER = 'wukong'   # 外机默认 (本机主仓用户是 WuKong, 外机常见小写)

$script:FrpcInstallDir = 'C:\frp'
$script:BundledFrpc = Join-Path $PSScriptRoot 'bin\frp\frpc.exe'
$script:BundledOpenSshZip = Join-Path $PSScriptRoot 'bin\openssh\OpenSSH-Win64.zip'
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
    # (主人 2026-08-04: 这块提示移到 Entry 启动时, S4/R1 都用同一值)
    # — 此处保留 param 灌入, prompt 改到 Entry 里

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
    # 清 ReadOnly attr: PowerShell Set-ItemProperty 在 ACL 紧时抛, 用 attrib -R 兜底
    try { attrib.exe -R "$Path" 2>&1 | Out-Null } catch {}
    try { Set-ItemProperty -Path $Path -Name IsReadOnly -Value $false -ErrorAction Stop } catch {}
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    try { icacls $Path /grant:r "${me}:(F)" 2>&1 | Out-Null } catch {
        Write-Warn "  icacls grant 失败: $($_.Exception.Message)"
        $ok = $false
    }
    return $ok
}

# ── ~/.ssh 整目录解锁 — 防 known_hosts 空 ACL / 跨机 SID 不匹配 / UNKNOWN SID ──
function Unlock-SshDir {
    <#
    解锁 ~/.ssh 整目录, 含:
      - 目录本身 + owner + 继承清空 + 当前用户/SYSTEM FullControl
      - 所有文件 (config / known_hosts / authorized_keys) 同样
      - 清 UNKNOWN SIDs (跨机写产生的脏 ACE)
    返 [bool]: 全部成功 true, 任意步失败 false
    #>
    param([string]$Dir = (Join-Path $env:USERPROFILE '.ssh'))
    if (-not (Test-Path $Dir)) {
        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    }
    $ok = $true
    $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    # 清 UNKNOWN SIDs (跨机 SID 残留, ssh 会报 Permission denied)
    # 直接扫 icacls 输出, 避免 .NET reflection 跨 PowerShell 版本踩坑
    try {
        $icaclsOut = & icacls.exe $Dir 2>&1 | Out-String
        # 匹配形如 "S-1-5-21-...-1003:(F)" 的行
        $sidPattern = '(S-1-5-\d+(?:-\d+)+(?:\-\d+)?):\([A-Z]+\)'
        $matches_found = [regex]::Matches($icaclsOut, $sidPattern)
        foreach ($m in $matches_found) {
            try { icacls $Dir /remove $m.Groups[1].Value 2>&1 | Out-Null } catch {}
        }
    } catch { Write-Warn "  清 UNKNOWN SID 跳过: $($_.Exception.Message)" }

    # 目录 owner + ACL
    try {
        icacls $Dir /inheritance:r /grant:r "${me}:(F)" "SYSTEM:(F)" 2>&1 | Out-Null
        icacls $Dir /setowner "$me" 2>&1 | Out-Null
    } catch {
        Write-Warn "  ~/.ssh 目录 ACL 失败: $($_.Exception.Message)"
        $ok = $false
    }

    # 遍历所有文件
    foreach ($f in (Get-ChildItem -Path $Dir -File -Force -ErrorAction SilentlyContinue)) {
        if (-not (Unlock-SshFile $f.FullName)) { $ok = $false }
        # UNKNOWN SID 也清文件级
        try {
            $icaclsOut = & icacls.exe $f.FullName 2>&1 | Out-String
            $sidPattern = '(S-1-5-\d+(?:-\d+)+(?:\-\d+)?):\([A-Z]+\)'
            $matches_found = [regex]::Matches($icaclsOut, $sidPattern)
            foreach ($m in $matches_found) {
                try { icacls $f.FullName /remove $m.Groups[1].Value 2>&1 | Out-Null } catch {}
            }
        } catch {}
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
    $unlockOk = Unlock-SshDir (Split-Path $script:SshCfg -Parent)
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
    $unlockOk = Unlock-SshDir (Split-Path $script:SshCfg -Parent)
    if (-not $unlockOk) {
        Write-Warn "写 ~/.ssh/config 跳过: ACL 解锁失败"
        return $false
    }
    # 清 Hidden / ReadOnly attr (OpenSSH 装时会加 Hidden)
    try { attrib.exe -R -H "$script:SshCfg" 2>&1 | Out-Null } catch {}
    try {
        # 先写临时文件再 Move, 绕开 AV 实时锁 (Defender/Avast 常锁 .ssh/config)
        $tmp = "$script:SshCfg.new"
        [System.IO.File]::WriteAllText($tmp, $Content, (New-Object System.Text.UTF8Encoding $false))
        Move-Item -Path $tmp -Destination $script:SshCfg -Force -ErrorAction Stop
        return $true
    } catch {
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
    取第一个 device id (config.xml 可能历史残留多个, VPS _safe_device_id
    regex [A-Za-z0-9._:-]{1,128} 不接受多行拼字符串 → 400).
    #>
    $syncthingCfg = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
    if (-not (Test-Path $syncthingCfg)) { return $null }
    try {
        $x = [xml](Get-Content $syncthingCfg -Raw)
        $id = $null
        if ($x.configuration.device[0].id) { $id = $x.configuration.device[0].id }
        elseif ($x.syncthing.device[0].id) { $id = $x.syncthing.device[0].id }
        if ($id -is [array]) { $id = $id[0] }
        return $id
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
    6 节 PreCheck 报告: 管理员 / OS / 账号 / 网络 / 环境 / 端口
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

    # 2. 账号 (大小写不敏感查找; 密码检查已删除 — 主人 2026-08-04 要求)
    $user = $script:State.LocalUser
    $matched = $null
    try {
        $matched = Get-LocalUser | Where-Object { $_.Name -ieq $user } | Select-Object -First 1
    } catch {}
    if ($matched) {
        Write-Host "  账号 $($matched.Name): ✅ 存在"
    } else {
        Write-Host "  账号 ${user}: ❌ 不存在 (本地用户列表里查不到)"
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

    # 6. VPS 设备 (合并原 Show-Status)
    Write-Host ""
    Write-Info "  VPS 设备:"
    $devList = Get-VpsDeviceList
    if ($devList -and $devList.devices) {
        foreach ($d in $devList.devices) {
            $status = if ($d.online) { 'online' } else { 'offline' }
            Write-Host "    [$status] $($d.device_name) port=$($d.capabilities.frpc.remote_port) user=$($d.capabilities.sshd.user)"
        }
    }
    else {
        Write-Host "    (VPS 不可达 / 无设备)"
    }

    # 8. 致命错误快照
    if ($script:State.LastError) {
        Write-Host ""
        Write-Host "  ⚠ 上次错误: $($script:State.LastError) (at $($script:State.LastErrorAt))"
    }
    Write-Host "=========================================" -ForegroundColor Cyan
}

# ─────────────────────────────────────────────────────────────────────
# Module 2 — Install (表驱动, 7 步 SC S2 S3 S4 S5 R1 SY)
# ─────────────────────────────────────────────────────────────────────
#region Module 2 — Install

# 单一源: 8 步定义
$script:InstallSteps = @(
    @{ Code = 'SC'; Fn = 'Install-OpenSSH'; Needs = @('Admin'); Critical = $true }
    @{ Code = 'S2'; Fn = 'Set-SshdConfig'; Needs = @('Admin'); Critical = $true }
    @{ Code = 'S3'; Fn = 'Add-FirewallRule22'; Needs = @('Admin'); Critical = $true }
    @{ Code = 'S4'; Fn = 'Install-Frpc'; Needs = @('Admin', 'FrpToken'); Critical = $false }
    @{ Code = 'S5'; Fn = 'Test-AccountPassword'; Needs = @('Admin'); Critical = $false }
    @{ Code = 'R1'; Fn = 'Register-ThisHost'; Needs = @('Bearer'); Critical = $false }
    @{ Code = 'SY'; Fn = 'Sync-VpsDevices'; Needs = @('Bearer'); Critical = $false }
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
        保留兼容 (无实际效果, 装就全装)
    #>
    param([string]$Mode = $script:State.InstallMode)

    Write-Info "========== Install =========="

    # 启动 PreCheck (干跑)
    Invoke-PreCheck
    if ($script:State.Fatal) {
        Write-Err "PreCheck 致命错, 退出 Install" -Critical
        return @{ ok = $false; failed = 'PreCheck' }
    }

    foreach ($step in $script:InstallSteps) {
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
            $msg = "$($step.Code) 抛错: $($_.Exception.Message) [$($_.Exception.GetType().FullName)]"
            Write-Err $msg -Critical:$step.Critical
            Write-Host "  堆栈: $($_.ScriptStackTrace)" -ForegroundColor DarkGray
            Write-Host "  位置: $($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
            if ($step.Critical) {
                return @{ ok = $false; failed = $step.Code; detail = $_.Exception.Message }
            }
        }

        if ($script:State.Fatal) {
            return @{ ok = $false; failed = 'fatal-flag' }
        }
    }

    Write-Info "========== Install 完成 =========="
    return @{ ok = $true }
}

# ── Step SC: OpenSSH Server + Client 一起装 ──
function Install-OpenSSH {
    <#
    合并 S1 + C1. 优先 bin 离线 (绕开 Get-WindowsCapability DISM COMException),
    fallback 到 capability. Server / Client 装成后, sshd 服务注册 + 自启.
    #>
    # 1. bin 离线优先 — 绕开 DISM COM 错
    $sshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
    $sshExe  = "$env:SystemRoot\System32\OpenSSH\ssh.exe"
    if ((Test-Path $sshdExe) -and (Test-Path $sshExe) -and (Get-Service sshd -ErrorAction SilentlyContinue)) {
        Write-Info "  OpenSSH Server + Client binaries 已装 — 跳过"
    }
    else {
        $workDir = Join-Path $env:TEMP 'ssh-deploy-openssh'
        $zip = Get-OpenSSHZip -WorkDir $workDir
        if ($zip) {
            $expanded = Expand-OpenSSHZip -ZipPath $zip.path -ExpandRoot $workDir
            $dest = "$env:SystemRoot\System32\OpenSSH"
            if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
            try {
                Copy-Item "$expanded\*" "$dest\" -Recurse -Force -ErrorAction Stop
                Write-Info "  OpenSSH binaries 已复制到 $dest (tier-1 bin)"
            }
            catch {
                Write-Warn "  bin 复制失败: $($_.Exception.Message) — 试 DISM"
                $zip = $null
            }
            if ($zip) {
                # ssh-keygen -A 生成 host keys
                try { & "$dest\ssh-keygen.exe" -A 2>&1 | Out-Null } catch {}
                # sc create sshd (仅当服务不存在)
                if (-not (Get-Service sshd -ErrorAction SilentlyContinue)) {
                    try {
                        sc.exe create sshd binPath= "`"$dest\sshd.exe`"" DisplayName= "OpenSSH SSH Server" start= auto 2>&1 | Out-Null
                    } catch {
                        Write-Warn "  sc create sshd 失败: $($_.Exception.Message)"
                    }
                }
                # ProgramData\ssh + 默认 sshd_config
                if (-not (Test-Path 'C:\ProgramData\ssh')) {
                    New-Item -ItemType Directory -Path 'C:\ProgramData\ssh' -Force | Out-Null
                }
                if ((Test-Path "$expanded\sshd_config_default") -and -not (Test-Path 'C:\ProgramData\ssh\sshd_config')) {
                    Copy-Item "$expanded\sshd_config_default" 'C:\ProgramData\ssh\sshd_config' -Force
                }
            }
        }
        else {
            Write-Warn "  bin 拿不到 — 试 DISM capability"
        }

        # 2. DISM fallback (仅当 bin 失败或拿不到时)
        if (-not (Test-Path $sshdExe) -or -not (Test-Path $sshExe)) {
            foreach ($name in @('OpenSSH.Server~~~~0.0.1.0', 'OpenSSH.Client~~~~0.0.1.0')) {
                $cap = $null
                try {
                    $cap = Get-WindowsCapability -Online -Name $name -ErrorAction Stop
                } catch [System.Runtime.InteropServices.COMException] {
                    $cap = $null
                } catch {
                    $cap = $null
                }
                if ($cap -and $cap.State -ne 'Installed') {
                    try {
                        Add-WindowsCapability -Online -Name $name -ErrorAction Stop | Out-Null
                        Write-Info "  $name 通过 DISM 装"
                    } catch {
                        Write-Warn "  $name DISM 装失败: $($_.Exception.Message)"
                    }
                }
            }
        }
    }

    # 3. 验证 + 启服务
    $sshdSvc = Get-Service sshd -ErrorAction SilentlyContinue
    if (-not $sshdSvc) {
        return @{ ok = $false; msg = 'OpenSSH 装失败 (bin + DISM 都不可用)' }
    }
    Set-Service sshd -StartupType Automatic -ErrorAction SilentlyContinue
    Start-Service sshd -ErrorAction SilentlyContinue
    Write-Info "  sshd 服务: $($sshdSvc.Status)"
    return @{ ok = $true }
}

# ── Step S2: sshd_config ──
function Set-SshdConfig {
    $src = "$env:ProgramData\ssh\sshd_config"
    if (-not (Test-Path $src)) {
        Write-Warn "  sshd_config 不存在: $src"
        return @{ ok = $false; msg = 'sshd_config 不存在' }
    }

    # 替换关键配置 (in-memory, 直接 overwrite 不备份)
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

    # 无脑装到 C:\frp (主人 2026-08-04 要求: 不检查存不存在, 覆盖保仓一致)
    $dest = Join-Path $script:FrpcInstallDir 'frpc.exe'
    Copy-Item $exe.Path $dest -Force -ErrorAction Stop
    Write-Info "  装到 $dest (覆盖)"

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
function Test-AccountPassword {
    <#
    non-Critical: 账号存在 + 有密码. 无密码只 warn, 不阻塞.
    (Win OpenSSH SAM 缓存, 设密码后下次 SSH 连生效, 不强求 restart)
    #>
    $user = $script:State.LocalUser

    $matched = $null
    try {
        $matched = Get-LocalUser | Where-Object { $_.Name -ieq $user } | Select-Object -First 1
        if ($matched -and $matched.Name -cne $script:State.LocalUser) {
            Write-Info "  账号大小写修正: $($script:State.LocalUser) → $($matched.Name)"
            $script:State.LocalUser = $matched.Name
        }
    }
    catch {}

    if (-not $matched) {
        Write-Warn "  账号 $user 不存在 (Win 本地用户列表里查不到)"
        return @{ ok = $false; msg = '账号不存在' }
    }

    if (-not $matched.PasswordRequired) {
        Write-Warn "  账号 $($matched.Name) 无密码 — SSH 密码认证会失败. 跑 'net user $($matched.Name) *' 设密码"
        return @{ ok = $true; noPassword = $true }
    }
    Write-Info "  账号 $($matched.Name) ✅ 有密码"
    return @{ ok = $true }
}

# ── Step C1: OpenSSH Client ──
function Install-OpenSSHClient {
    # 同 S1: $ErrorActionPreference='Stop' 覆盖 SilentlyContinue, 必须 try/catch COMException
    $cap = $null
    try {
        $cap = Get-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 -ErrorAction Stop
    } catch [System.Runtime.InteropServices.COMException] {
        Write-Debug "  Get-WindowsCapability (Client) COM 异常: $($_.Exception.Message)"
        $cap = $null
    } catch {
        Write-Debug "  Get-WindowsCapability (Client) 异常: $($_.Exception.Message)"
        $cap = $null
    }
    $sshExe = "$env:SystemRoot\System32\OpenSSH\ssh.exe"
    # 已装
    if ($cap -and $cap.State -eq 'Installed') {
        Write-Info "  OpenSSH Client 已装 (capability), 跳过"
        return @{ ok = $true }
    }
    # cap null + ssh.exe 已装 → 跳
    elseif ($null -eq $cap -and (Test-Path $sshExe)) {
        Write-Info "  OpenSSH Client 检测不到 capability 但 ssh.exe 已存在 — 跳过"
        return @{ ok = $true }
    }
    # cap 返值未装 → DISM
    elseif ($cap) {
        try {
            Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0 -ErrorAction Stop | Out-Null
            Write-Info "  OpenSSH Client 已通过 DISM 装"
        }
        catch {
            Write-Warn "  Add-WindowsCapability (Client) 失败: $($_.Exception.Message)"
            return @{ ok = $false; msg = 'DISM 装 Client 失败' }
        }
    }
    # 兜底离线装 (绕开 install-sshl.ps1 同样 COM 错)
    else {
        $workDir = Join-Path $env:TEMP 'ssh-deploy-openssh'
        $zip = Get-OpenSSHZip -WorkDir $workDir
        if (-not $zip) {
            return @{ ok = $false; msg = 'capability 不可用 + 离线包拿不到' }
        }
        $expanded = Expand-OpenSSHZip -ZipPath $zip.path -ExpandRoot $workDir
        $dest = "$env:SystemRoot\System32\OpenSSH"
        if (-not (Test-Path $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
        try {
            Copy-Item "$expanded\*" "$dest\" -Recurse -Force -ErrorAction Stop
            Write-Info "  OpenSSH Client binaries 已复制到 $dest"
        } catch {
            return @{ ok = $false; msg = "Client binaries 复制失败: $($_.Exception.Message)" }
        }
    }
    return @{ ok = $true }
}

# ── Step SY: 同步 VPS 设备 (config + alias) ──
function Sync-VpsDevices {
    <#
    合并 C2 + C3. 拉 VPS /device/list → 写 ~/.ssh/config wpc-* 段 + PowerShell alias.
    保留 marker 块, 只换 wpc-* 段, 不动用户其他 Host.
    #>
    $list = Get-VpsDeviceList
    if (-not $list) {
        Write-Warn "  /device/list 失败 — 跳过 (看 LastApiError)"
        return @{ ok = $false; msg = 'device list 失败' }
    }
    $devices = $list.devices
    if (-not $devices) { $devices = @() }

    # 列出当前 VPS 设备清单 (主人 2026-08-04: 写之前先看)
    Write-Host ""
    Write-Info "  VPS 设备清单 ($($devices.Count) 条):"
    if ($devices.Count -eq 0) {
        Write-Host "    (无)" -ForegroundColor DarkGray
    }
    else {
        foreach ($d in $devices) {
            $name = $d.device_name
            $usr = $d.capabilities.sshd.user
            $port = $d.capabilities.frpc.remote_port
            Write-Host ("    {0,-20} port={1,-5} user={2}" -f $name, $port, $usr)
        }
    }
    Write-Host ""

    # 1. ~/.ssh/config wpc-* 段
    if (-not (Test-Path $script:SshDir)) { New-Item -ItemType Directory -Path $script:SshDir -Force | Out-Null }
    $cfgRead = Read-SshConfig
    if (-not $cfgRead.ok) {
        Write-Warn "  读 ~/.ssh/config 失败 ($($cfgRead.status): $($cfgRead.err)) — 跳过"
        return @{ ok = $false; msg = 'config 读失败' }
    }
    $cfgRaw = $cfgRead.content
    $cfgRaw = [regex]::Replace($cfgRaw, $script:MarkerConfig, '')

    $cfgBlock = "# ===== ssh-deploy: VPS devices =====`n"
    $cfgCount = 0
    foreach ($d in $devices) {
        $name = $d.device_name
        if (-not $name) { continue }
        $usr = $d.capabilities.sshd.user
        $port = $d.capabilities.frpc.remote_port
        if (-not $usr -or -not $port) { continue }
        $cfgBlock += "Host wpc-$name`n  HostName $($script:State.VpsHost)`n  Port $port`n  User $usr`n  ServerAliveInterval 30`n  ServerAliveCountMax 3`n`n"
        $cfgCount++
    }
    $cfgBlock += "# ===== END ssh-deploy =====`n`n"
    $cfgRaw = $cfgBlock + $cfgRaw
    $written = Write-SshConfig $cfgRaw
    if (-not $written) {
        Write-Warn "  写 ~/.ssh/config 失败"
    }
    else {
        Write-Info "  ~/.ssh/config 写了 $cfgCount 个 wpc-* 段"
    }

    # 2. PowerShell alias
    $profileFile = $script:ProfilePath
    if (-not (Test-Path $profileFile)) { New-Item -ItemType File -Path $profileFile -Force | Out-Null }
    $aliasRaw = Get-Content $profileFile -Raw -ErrorAction SilentlyContinue
    if (-not $aliasRaw) { $aliasRaw = '' }
    $aliasRaw = [regex]::Replace($aliasRaw, $script:MarkerAlias, '')

    $aliasBlock = "# ===== ssh-deploy aliases =====`n"
    foreach ($d in $devices) {
        $name = $d.device_name
        if (-not $name) { continue }
        $aliasBlock += "Set-Alias -Name wpc-$name -Value ssh -Force`n"
    }
    $aliasBlock += "# ===== END ssh-deploy aliases =====`n"
    $aliasRaw = $aliasBlock + "`n" + $aliasRaw
    [System.IO.File]::WriteAllText($profileFile, $aliasRaw, [System.Text.UTF8Encoding]::new($false))
    Write-Info "  $profileFile 写了 $($devices.Count) 个 alias"

    return @{ ok = $true; count = $cfgCount }
}

# ── helpers (OpenSSH zip) ──
function Get-OpenSSHZip {
    <#
    3-tier:
      1. Bundled: $PSScriptRoot\bin\openssh\OpenSSH-Win64.zip
      2. Cached:  $WorkDir\OpenSSH-Win64.zip
      3. Network: GitHub raw
    #>
    param([string]$WorkDir)
    if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null }
    # 1. bundled
    if (Test-Path $script:BundledOpenSshZip -PathType Leaf) {
        return @{ path = $script:BundledOpenSshZip; source = 'bundled' }
    }
    # 2. cached
    $localZip = Join-Path $WorkDir $script:OPENSSH_ZIP_NAME
    if (Test-Path $localZip -PathType Leaf) {
        return @{ path = $localZip; source = 'cached' }
    }
    # 3. network
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
    host 名 + frp port 在启动时 (Entry) 已 prompt 主人, S4 + R1 都用同一值.
    #>
    $deviceId = Get-DeviceIdLocal
    # VPS _safe_device_id regex = [A-Za-z0-9._:-]{1,128}
    # 旧 config.xml 可能多 device id 残留 / 拼字符串, 必须单值合法
    if (-not $deviceId -or $deviceId -is [array] -or ($deviceId -notmatch '^[A-Za-z0-9._:-]{1,128}$')) {
        $deviceId = [guid]::NewGuid().ToString()
        Write-Warn "  Syncthing device id 不合法 (无/多/含非法字符), 用临时 UUID: $deviceId"
    }

    # 查冲突 (主人 2026-08-04: device_name 覆盖静默, remote_port 冲突 prompt 确认)
    $force = $false

    $list = Invoke-VpsApi -Method GET -Path '/device/list'
    if ($list -and $list.devices) {
        # 同 device_name (server 自动覆盖, 仅 INFO)
        $sameName = @($list.devices | Where-Object { $_.device_name -eq $script:State.ServerName })
        if ($sameName.Count -gt 0) {
            Write-Info "  同名 device '$($script:State.ServerName)' 已存在, 将覆盖"
        }
        # 端口被**不同** device 占用 → prompt 确认
        $portOwner = $null
        foreach ($d in $list.devices) {
            $p = $d.capabilities.frpc.remote_port
            if ($p -eq $script:State.FrpcPort -and $d.device_name -ne $script:State.ServerName) {
                $portOwner = $d
                break
            }
        }
        if ($portOwner) {
            Write-Warn "  端口 $($script:State.FrpcPort) 已被 '$($portOwner.device_name)' 占用"
            $ans = Read-Host "  覆盖占用方? (yes/no)"
            if ($ans -ne 'yes') {
                Write-Info "  取消 — 改 frp port 或先 Unregister 占用方"
                return @{ ok = $false; msg = 'port conflict, cancelled' }
            }
            $force = $true
            Write-Warn "  确认覆盖, 将踢出 '$($portOwner.device_name)'"
        }
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
        force        = $force
    }
    $resp = Invoke-VpsApi -Method POST -Path '/device/register' -Body $body
    if ($resp -and ($resp.PSObject.Properties.Name -contains 'device_id' -or $resp.PSObject.Properties.Name -contains 'auth_token')) {
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

    # 2. 杀 frpc + 删任务 (文件保留, 主人 2026-08-04 要求)
    Write-Info "  杀 frpc + 删 frpc-bg 任务..."
    Get-Process -Name frpc -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $task = Get-ScheduledTask 'frpc-bg' -ErrorAction SilentlyContinue
    if ($task) { Unregister-ScheduledTask -TaskName 'frpc-bg' -Confirm:$false }
    $oldTask = Get-ScheduledTask 'frpc-autostart' -ErrorAction SilentlyContinue
    if ($oldTask) { Unregister-ScheduledTask -TaskName 'frpc-autostart' -Confirm:$false }
    Write-Info "  C:\frp\ 保留 (主人手动用)"

    # 3. 停 sshd
    Stop-Service sshd -Force -ErrorAction SilentlyContinue
    Set-Service sshd -StartupType Disabled -ErrorAction SilentlyContinue

    # 4. 清 ~/.ssh/config ssh-deploy 段
    if (Test-Path $script:SshCfg) {
        $cfgRead = Read-SshConfig
        if ($cfgRead.ok) {
            $raw = [regex]::Replace($cfgRead.content, $script:MarkerConfig, '')
            $null = Write-SshConfig $raw
        }
    }
    # 5. 清 PROFILE alias 段
    if (Test-Path $script:ProfilePath) {
        $raw = Get-Content $script:ProfilePath -Raw
        $raw = [regex]::Replace($raw, $script:MarkerAlias, '')
        [System.IO.File]::WriteAllText($script:ProfilePath, $raw, [System.Text.UTF8Encoding]::new($false))
    }

    # 6. 删 poller 任务
    $poller = Get-ScheduledTask 'ssh-deploy-poller' -ErrorAction SilentlyContinue
    if ($poller) { Unregister-ScheduledTask -TaskName 'ssh-deploy-poller' -Confirm:$false }

    Write-Ok "卸载完成"
}

#endregion

# ─────────────────────────────────────────────────────────────────────
# Module 5 — Menu + Dispatch
# ─────────────────────────────────────────────────────────────────────
#region Module 5 — Menu

function Show-Menu {
    Write-Host ""
    Write-Host "========== ssh-deploy v$($script:VERSION) ==========" -ForegroundColor Cyan
    Write-Host "  [1] Install"
    Write-Host "  [2] 同步 VPS 设备"
    Write-Host "  [3] Unregister 主机"
    Write-Host "  [4] Uninstall 本机"
    Write-Host "  [0] Exit"
    Write-Host ""
}

function Invoke-MenuLoop {
    do {
        Show-Menu
        $choice = Read-Host "选"
        switch ($choice) {
            '1' { Invoke-Install -Mode $script:State.InstallMode }
            '2' { $null = Sync-VpsDevices }
            '3' { $null = Unregister-Host }
            '4' { Invoke-Uninstall }
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
Write-Host "  VPS: $($script:State.VpsHost)  Bearer: $bearerShort..." -ForegroundColor DarkGray

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

# 启动最前面: host 名 + frp port 集中 prompt (主人 2026-08-04: 放最前面, S4/R1 都用同一值)
# 仅当没显式 param 时才问, 自动化脚本 (irm|iex) 直回车走默认
if (-not $ServerName -or -not $FrpSshPort) {
    Write-Host ""
    Write-Host "  === 主机标识 / 端口 ===" -ForegroundColor Cyan
    if (-not $ServerName) {
        $defaultName = $script:State.ServerName
        $input = Read-Host "  host 名 (默认 $defaultName,直回车接受)"
        if ($input) { $script:State.ServerName = $input.ToLower().Trim() }
    }
    if (-not $FrpSshPort) {
        $defaultPort = $script:State.FrpcPort
        $inputPort = Read-Host "  frp remote port (默认 $defaultPort,直回车接受)"
        $parsedPort = 0
        if ($inputPort -and [int]::TryParse($inputPort, [ref]$parsedPort) -and $parsedPort -gt 0 -and $parsedPort -lt 65536) {
            $script:State.FrpcPort = $parsedPort
        }
    }
    Write-Host ""
}

# 启动自动 PreCheck (主人 2026-08-04 要求 — 不再单独菜单跑)
Invoke-PreCheck

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
