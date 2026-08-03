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
      [3] ~~Switch~~ 合并到 [2] Status(自动同步 VPS 清单 → 重写 config + alias)
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
    # PS 7+ 不认 `irm | iex`,走两步:下文件 → 调
    $tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/win/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
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
    [string]$InstallMode = 'both',
    # 密钥文档路径(.env 风格 KEY=VALUE),外机部署由主人指定(u盘/网盘路径)
    [string]$TokenFile
)

# 启动计时(最先,任何慢操作之前)
$script:startTime = Get-Date

# 路径常量(前置,Defender 排除用)
$FrpcInstallDir = 'C:\frp'

# 强制 TLS 1.2 — PS 5.1 默认 TLS 1.0,GitHub raw + frp release 都拒
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Defender 排除:OpenSSH zip 解压到 $TEMP,frpc.exe 是常见 PUA 检测目标
# 失败不致命(无 Defender / 已加 / 权限不足)
try {
    Add-MpPreference -ExclusionPath "$env:TEMP" -ErrorAction Stop
    Add-MpPreference -ExclusionPath $FrpcInstallDir -ErrorAction Stop
} catch { }

# 显式 assert 管理员(icacls / sc create / Copy-Item → System32 都要 admin)
function Test-Administrator {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-Administrator)) {
    Write-Host "❌ 需管理员 PowerShell(右键 '终端(管理员)')" -ForegroundColor Red
    exit 1
}

$ErrorActionPreference = 'Stop'

# ---------- 常量 ----------
$DEFAULT_VPS = '8.163.106.31'
$DEFAULT_PORT = 6000
$DEFAULT_USER = 'WuKong'
$OPENSSH_ZIP_NAME = 'OpenSSH-Win64.zip'
$OPENSSH_GH_URL = 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/openssh/OpenSSH-Win64.zip'
$sshDir = "$env:USERPROFILE\.ssh"
$cfg = "$sshDir\config"
$DEFAULT_TOKEN_CACHE = Join-Path $sshDir 'deploy-secrets.md'

# ---------- Token helper 函数(前置定义,供下方三态逻辑调用) ----------
function Initialize-TokenCache {
    param([string]$SourcePath)
    if (-not $SourcePath -or -not (Test-Path $SourcePath)) {
        Write-Host "❌ -TokenFile '$SourcePath' 不存在" -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path $sshDir)) {
        New-Item -ItemType Directory -Path $sshDir -Force | Out-Null
    }
    try {
        Copy-Item -Path $SourcePath -Destination $DEFAULT_TOKEN_CACHE -Force -ErrorAction Stop
        # icacls 限当前用户读写(模拟 Linux 600)
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        icacls $DEFAULT_TOKEN_CACHE /inheritance:r /grant:r "${me}:(R,W)" "SYSTEM:(R)" 2>&1 | Out-Null
        Write-Host "✅ token 文档已复制到默认位置:$DEFAULT_TOKEN_CACHE" -ForegroundColor Green
        Write-Host "   (ACL 限当前用户 + SYSTEM 读)" -ForegroundColor DarkGray
        $script:TokenFile = $DEFAULT_TOKEN_CACHE
    } catch {
        Write-Host "❌ 复制 token 文档失败:$($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

function Get-TokenFromFile {
    param([string]$FilePath, [string]$Key)
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
    } catch {
        Write-Host "⚠️  读 token 文件失败:$($_.Exception.Message)" -ForegroundColor Yellow
    }
    return $null
}

# ---------- Token 文档处理 ----------
# 三态:
#   1. 显式 -TokenFile → 若 ≠ 默认 → 复制到默认 + icacls;否则直接用
#   2. 无 -TokenFile + 默认位置有文件 → 自动用默认(后续运行)
#   3. 无 -TokenFile + 默认位置无文件 → 首次,prompt 问文档路径 → 复制(之后回到态 2)
if ($TokenFile) {
    if ($TokenFile -ne $DEFAULT_TOKEN_CACHE) {
        Initialize-TokenCache -SourcePath $TokenFile
    }
} elseif (Test-Path $DEFAULT_TOKEN_CACHE) {
    $script:TokenFile = $DEFAULT_TOKEN_CACHE
    Write-Host "ℹ️  从默认位置读取 token 文档:$DEFAULT_TOKEN_CACHE" -ForegroundColor DarkGray
} else {
    # 首次:问主人要文档路径
    Write-Host "⚠️  未找到默认 token 文档 ($DEFAULT_TOKEN_CACHE)" -ForegroundColor Yellow
    $provided = Read-Host "请提供密钥文档完整路径"
    if (-not $provided) {
        Write-Host "❌ 未提供 token 文档,退出" -ForegroundColor Red
        exit 1
    }
    Initialize-TokenCache -SourcePath $provided
}

# ---------- helper: OpenSSH zip ----------
function Get-OpenSSHZip {
    param([string]$WorkDir)
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
    New-Item -ItemType Directory -Path $expandDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    $zipFull = [System.IO.Path]::GetFullPath($ZipPath)
    # 用 ZipArchive 显式枚举解压(ExtractToDirectory 在某些 Defender 版本仍被拦)
    $archive = [System.IO.Compression.ZipFile]::OpenRead($zipFull)
    try {
        foreach ($entry in $archive.Entries) {
            if (-not $entry.Name) { continue }  # 跳目录条目(最后一段 Name 为空)
            $destPath = Join-Path $expandDir $entry.FullName
            $destDir = Split-Path $destPath -Parent
            if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
            $entryStream = $entry.Open()
            try {
                $fileStream = [System.IO.File]::Create($destPath)
                try { $entryStream.CopyTo($fileStream) } finally { $fileStream.Close() }
            } finally { $entryStream.Close() }
        }
    } finally { $archive.Dispose() }
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
    # VpsHost 缺时填默认(Status 流程不调 Get-*Params)
    if (-not $VpsHost) { $VpsHost = $DEFAULT_VPS; $script:VpsHost = $DEFAULT_VPS }
    # Bearer 缺时,从 token 文档补救(Status 流程不调 Get-*Params,必须自动读)
    if (-not $BearerToken -and $TokenFile) {
        $auto = Get-TokenFromFile -FilePath $TokenFile -Key 'BEARER_TOKEN'
        if ($auto) {
            $BearerToken = $auto
            $script:BearerToken = $auto
        }
    }
    if (-not $BearerToken) {
        Write-Host "⚠️  无 Bearer token(也没 token 文档),跳过 VPS API" -ForegroundColor Yellow
        return $null
    }
    try {
        $url = "http://${VpsHost}:8080/device/list"
        $resp = Invoke-RestMethod -Uri $url -Headers (Get-VpsHeaders) -TimeoutSec 15 -ErrorAction Stop
        # 兼容老 caller: 把 devices 包装成 servers 字段
        return @{ version = $resp.version; servers = $resp.devices }
    } catch {
        Write-Host "⚠️  拉 VPS device list 失败:$($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Register-ThisHost {
    Get-RegisterParams
    if (-not $BearerToken) {
        Write-Host "需要 -BearerToken" -ForegroundColor Yellow
        return $false
    }
    # 优先用 Syncthing device_id (新 API 要求);无则 hostname 临时 id
    $syncthingCfg = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
    $deviceId = $null
    if (Test-Path $syncthingCfg) {
        try {
            $c = [xml](Get-Content $syncthingCfg -Raw)
            # Syncthing 新版根元素 <configuration>, 老版 <syncthing>
            if ($c.configuration.device.id) { $deviceId = $c.configuration.device.id }
            elseif ($c.syncthing.device.id) { $deviceId = $c.syncthing.device.id }
        } catch {}
    }
    if (-not $deviceId) {
        Write-Host "⚠️  Syncthing 未装 / config.xml 无 device id" -ForegroundColor Yellow
        Write-Host "    推荐: 菜单 [8] Syncthing 协同 → [1] 装 Syncthing → [2] 登记本机到 VPS" -ForegroundColor Yellow
        $useFallback = Read-Host "继续用 hostname 临时 id 注册? (y/n)"
        if ($useFallback -ne 'y') { return $false }
        # 临时 id: hostname-epoch (避免冲突)
        $deviceId = "$($ServerName)-$(Get-Date -UFormat '%s')-tmp"
    }
    # frpc remote_port 从 frpc.toml 读 (Win 端迁移后路径)
    $frpcPort = $FrpSshPort
    if (-not $frpcPort -or $frpcPort -eq 0) {
        $frpcToml = 'C:\frp\frpc.toml'
        if (Test-Path $frpcToml) {
            foreach ($line in Get-Content $frpcToml) {
                if ($line -match 'remotePort\s*=\s*(\d+)') { $frpcPort = [int]$Matches[1]; break }
            }
        }
    }
    # 构 capabilities (分两步避免 ConvertTo-Json 把嵌套字典当 @{}-of-@{} 序列化)
    $caps = [ordered]@{
        sshd      = [ordered]@{ user = $LocalUser }
        syncthing = [ordered]@{ folders = @() }
    }
    if ($frpcPort) {
        $caps.frpc = [ordered]@{ remote_port = [int]$frpcPort }
    }
    $payload = [ordered]@{
        device_id    = $deviceId
        device_name  = $ServerName
        capabilities = $caps
    } | ConvertTo-Json -Compress -Depth 10
    try {
        $url = "http://${VpsHost}:8080/device/register"
        $resp = Invoke-RestMethod -Uri $url -Method POST -ContentType 'application/json' -Headers (Get-VpsHeaders) -Body $payload -TimeoutSec 8 -ErrorAction Stop
        Write-Host "✅ 已注册 $($resp.device_name) (device_id=$deviceId)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "❌ register 失败:$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Unregister-ThisHost {
    # 兼容旧调用:已并入 Unregister-Host(菜单 [4])
    Write-Host "⚠️  Unregister-ThisHost 已并入 Unregister-Host(菜单 [4])" -ForegroundColor Yellow
    Unregister-Host
}

# ---------- 注销主机(本机 / 任意,从 VPS 列表挑) ----------
function Unregister-Host {
    if (-not $BearerToken -and $TokenFile) {
        $auto = Get-TokenFromFile -FilePath $TokenFile -Key 'BEARER_TOKEN'
        if ($auto) { $BearerToken = $auto; $script:BearerToken = $auto }
    }
    if (-not $BearerToken) {
        Write-Host "❌ 无 Bearer token,不能注销" -ForegroundColor Red
        return $false
    }
    if (-not $VpsHost) { $VpsHost = $DEFAULT_VPS; $script:VpsHost = $DEFAULT_VPS }

    $resp = Get-VpsHostsJson
    if (-not $resp -or -not $resp.servers -or $resp.servers.Count -eq 0) {
        Write-Host "VPS 当前无主机注册" -ForegroundColor Yellow
        return $false
    }

    Write-Host ""
    Write-Host "--- VPS 当前注册主机 ---" -ForegroundColor Cyan
    $resp.servers | ForEach-Object {
        $frpcPort = if ($_.capabilities -and $_.capabilities.frpc) { $_.capabilities.frpc.remote_port } else { '-' }
        $user = if ($_.capabilities -and $_.capabilities.sshd) { $_.capabilities.sshd.user } else { '-' }
        $isThis = if ($_.device_name -eq $env:COMPUTERNAME.ToLower()) { " ← 本机" } else { "" }
        Write-Host ("  {0,-20} port {1,-5} user {2}{3}" -f $_.device_name, $frpcPort, $user, $isThis) -ForegroundColor $(if ($isThis){'Green'}else{'Gray'})
    }
    Write-Host ""
    $target = Read-Host "输入要注销的主机名(device_name)"
    if (-not $target) {
        Write-Host "❌ 取消(空输入)" -ForegroundColor Yellow
        return $false
    }
    $targetDev = $resp.servers | Where-Object { $_.device_name -eq $target } | Select-Object -First 1
    if (-not $targetDev) {
        Write-Host "❌ VPS 无此主机:$target" -ForegroundColor Red
        return $false
    }
    $confirm = Read-Host "确认注销 '$target'? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "❌ 取消" -ForegroundColor Yellow
        return $false
    }
    try {
        $url = "http://${VpsHost}:8080/device/deregister"
        $payload = @{ device_id = $targetDev.device_id } | ConvertTo-Json -Compress
        $resp2 = Invoke-RestMethod -Uri $url -Method POST -ContentType 'application/json' -Headers (Get-VpsHeaders) -Body $payload -TimeoutSec 8 -ErrorAction Stop
        Write-Host "✅ 已注销 '$target'(移除 $($resp2.removed) 条)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "❌ deregister 失败:$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ---------- helper: SSH config 生成 ----------
function Generate-SSHConfigFromVPS {
    $resp = Get-VpsHostsJson
    if (-not $resp -or -not $resp.servers) {
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

    # 逐 device 写
    foreach ($s in $resp.servers) {
        $frpc = $s.capabilities.frpc
        if (-not $frpc -or -not $frpc.remote_port) { continue }
        $user = if ($s.capabilities.sshd) { $s.capabilities.sshd.user } else { $env:USERNAME }
        $alias = "wpc-$($s.device_name)"
        $segment = @"

# ===== ssh-deploy: $($s.device_name) =====
Host $alias
    HostName $VpsHost
    Port $($frpc.remote_port)
    User $user
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
"@
        [System.IO.File]::AppendAllText($cfg, $segment, [System.Text.UTF8Encoding]::new($false))
        Write-Host "  ✅ alias $alias → $VpsHost :$($frpc.remote_port) user $user" -ForegroundColor Green
    }
}

# ---------- helper: Write-Step ----------
function Write-Step($n, $msg) {
    $elapsed = [int]((Get-Date) - $script:startTime).TotalSeconds
    Write-Host ""
    Write-Host "[$n] $msg" -ForegroundColor Cyan
    Write-Host "    ⏱ 累计 ${elapsed}s" -ForegroundColor DarkGray
}

# ---------- helper: 按菜单按需 prompt ----------
function Get-InstallParams {
    # Install 需要所有变量
    if (-not $VpsHost) {
        $VpsHost = Read-Host "VPS 公网 IP [$DEFAULT_VPS]"
        if (-not $VpsHost) { $VpsHost = $DEFAULT_VPS }
        $script:VpsHost = $VpsHost
    }
    if (-not $BearerToken) {
        if ($TokenFile) {
            $BearerToken = Get-TokenFromFile -FilePath $TokenFile -Key 'BEARER_TOKEN'
            if (-not $BearerToken) {
                Write-Host "❌ -TokenFile '$TokenFile' 里没找到 BEARER_TOKEN" -ForegroundColor Red
                exit 1
            }
            Write-Host "✅ Bearer token 从 token 文件读取(长度 $($BearerToken.Length))" -ForegroundColor Green
        } else {
            $secure = Read-Host "ssh-deploy-api Bearer token(留空=不调 VPS API)" -AsSecureString
            if ($secure -and $secure.Length -gt 0) {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $BearerToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            } else {
                $BearerToken = ''
            }
        }
        $script:BearerToken = $BearerToken
    }
    if (-not $FrpToken) {
        if ($TokenFile) {
            $FrpToken = Get-TokenFromFile -FilePath $TokenFile -Key 'FRP_TOKEN'
            if ($FrpToken) {
                Write-Host "✅ FRP token 从 token 文件读取(长度 $($FrpToken.Length))" -ForegroundColor Green
            }
        } else {
            $secure = Read-Host "FRPS 双向校验 token(留空=跳过 frpc 配置)" -AsSecureString
            if ($secure -and $secure.Length -gt 0) {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $FrpToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            } else {
                $FrpToken = ''
            }
        }
        $script:FrpToken = $FrpToken
    }
    if ($FrpSshPort -le 0) {
        $portInput = Read-Host "FRP SSH 转发端口 [$DEFAULT_PORT]"
        if ($portInput) { $FrpSshPort = [int]$portInput } else { $FrpSshPort = $DEFAULT_PORT }
        $script:FrpSshPort = $FrpSshPort
    }
    if (-not $LocalUser) {
        $userInput = Read-Host "本机 Win11 账号用户名 [$DEFAULT_USER]"
        if ($userInput) { $LocalUser = $userInput } else { $LocalUser = $DEFAULT_USER }
        $script:LocalUser = $LocalUser
    }
    if (-not $ServerName) {
        $defaultName = $env:COMPUTERNAME.ToLower()
        $nameInput = Read-Host "VPS 注册名 [$defaultName]"
        if ($nameInput) { $ServerName = $nameInput } else { $ServerName = $defaultName }
        $script:ServerName = $ServerName
    }
}

function Get-RegisterParams {
    # Register / Unregister 只需 VPS 连接 + 注册名
    if (-not $VpsHost) {
        $VpsHost = Read-Host "VPS 公网 IP [$DEFAULT_VPS]"
        if (-not $VpsHost) { $VpsHost = $DEFAULT_VPS }
        $script:VpsHost = $VpsHost
    }
    if (-not $BearerToken) {
        if ($TokenFile) {
            $BearerToken = Get-TokenFromFile -FilePath $TokenFile -Key 'BEARER_TOKEN'
            if (-not $BearerToken) {
                Write-Host "❌ -TokenFile '$TokenFile' 里没找到 BEARER_TOKEN" -ForegroundColor Red
                exit 1
            }
            Write-Host "✅ Bearer token 从 token 文件读取(长度 $($BearerToken.Length))" -ForegroundColor Green
        } else {
            $secure = Read-Host "ssh-deploy-api Bearer token(留空=不调 VPS API)" -AsSecureString
            if ($secure -and $secure.Length -gt 0) {
                $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
                $BearerToken = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr)
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            } else {
                $BearerToken = ''
            }
        }
        $script:BearerToken = $BearerToken
    }
    # ServerName:每次进 Register/Unregister 菜单都重问(避免上一次的输入固化)
    $defaultName = $env:COMPUTERNAME.ToLower()
    $nameInput = Read-Host "VPS 注册名 [$defaultName]"
    if ($nameInput) { $ServerName = $nameInput } else { $ServerName = $defaultName }
    $script:ServerName = $ServerName
}

# ---------- 1. OpenSSH Server install ----------
function Install-OpenSSHServer {
    Write-Step "S1" "装 OpenSSH Server"
    $sshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
    $serverCap = $null
    try {
        $serverCap = (Get-WindowsCapability -Online -Name 'OpenSSH.Server*' -ErrorAction SilentlyContinue 2>$null) | Where-Object { $_.State -eq 'Installed' }
    } catch { $serverCap = $null }

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
        # 当前已是管理员,直接同步跑 bat
        $p = Start-Process cmd.exe -ArgumentList '/c', "`"$tmpBat`"" -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($p.ExitCode -ne 0) {
            Write-Host "⚠️  bat exit=$($p.ExitCode)" -ForegroundColor Yellow
        }
        if (Test-Path $logPath) {
            Get-Content $logPath
        } else {
            Write-Host "❌ bat 没写 log" -ForegroundColor Red
        }
        Remove-Item $tmpBat -Force -ErrorAction SilentlyContinue
        Write-Host "✅ OpenSSH Server 装完" -ForegroundColor Green
    } else {
        Write-Host "zip + WinSxS 都不可用,走 Windows Update(慢)..." -ForegroundColor Yellow
        Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0' | Out-Null
    }
    Start-Sleep -Seconds 3
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
"C:\Windows\System32\OpenSSH\sshd.exe" -t -f "$cfgPath" >> "%LOG%" 2>&1
if errorlevel 1 (
    echo sshd_config_VALIDATION_FAILED >> "%LOG%"
    exit /b 1
)
sc start sshd >> "%LOG%" 2>&1
ping -n 3 127.0.0.1 >nul
sc query sshd >> "%LOG%" 2>&1
endlocal
"@
    [System.IO.File]::WriteAllText($tmpBat, $writeScript, [System.Text.UTF8Encoding]::new($false))
    # 当前已是管理员,直接同步跑 bat
    $p = Start-Process cmd.exe -ArgumentList '/c', "`"$tmpBat`"" -Wait -PassThru -NoNewWindow -ErrorAction Stop
    if (Test-Path $logPath) {
        Get-Content $logPath
        if (Select-String -Path $logPath -Pattern 'sshd_config_VALIDATION_FAILED' -ErrorAction SilentlyContinue) {
            Write-Error "sshd 配置校验失败 — 改 $cfgPath 后重跑"
            return
        }
    } else {
        Write-Host "❌ bat 没写 log,看 stdout/cmd 错误" -ForegroundColor Red
    }
    if ($p.ExitCode -ne 0) {
        Write-Host "⚠️  bat exit=$($p.ExitCode)" -ForegroundColor Yellow
    }
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

    # 三态检测:frpc-bg 任务 + C:\frp\frpc.exe + C:\frp\frpc.toml
    # 任一缺失 → 完整重建(包含 frpc-bg 计划任务带 RestartOnFailure,frpc 死了自动拉)
    $taskOk = [bool](Get-ScheduledTask frpc-bg -ErrorAction SilentlyContinue)
    $exePath = Join-Path $FrpcInstallDir 'frpc.exe'
    $tomlPath = Join-Path $FrpcInstallDir 'frpc.toml'
    $exeOk = (Test-Path $exePath) -and (Get-Item $exePath).Length -gt 1MB
    $tomlOk = Test-Path $tomlPath
    if ($taskOk -and $exeOk -and $tomlOk) {
        Write-Host "✅ frpc 环境完整(task + exe + toml),无需重建" -ForegroundColor Green
    } else {
        Write-Host "⚠️  检测到缺失:" -ForegroundColor Yellow
        Write-Host "    task:    $taskOk" -ForegroundColor DarkGray
        Write-Host "    exe:     $exeOk  ($exePath)" -ForegroundColor DarkGray
        Write-Host "    toml:    $tomlOk  ($tomlPath)" -ForegroundColor DarkGray
        Write-Host "    → 开始重建..." -ForegroundColor Yellow
    }

    # 1) 建目录
    if (-not (Test-Path $FrpcInstallDir)) {
        New-Item -ItemType Directory -Path $FrpcInstallDir -Force | Out-Null
        Write-Host "  ✅ 建目录 $FrpcInstallDir" -ForegroundColor Green
    }

    # 2) 拉 frpc.exe(若缺失或大小异常)
    if (-not $exeOk) {
        $remoteFrpc = 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/frp/frpc.exe'
        $tmpFrpc = Join-Path $env:TEMP 'frpc.exe'
        Write-Host "  下载 frpc.exe (raw,绕过 zip/解压)..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri $remoteFrpc -OutFile $tmpFrpc -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        } catch {
            Write-Host "❌ 下载失败:$($_.Exception.Message)" -ForegroundColor Red
            return
        }
        if ((Get-Item $tmpFrpc).Length -lt 1MB) {
            Write-Host "❌ 下载文件大小异常,放弃" -ForegroundColor Red
            return
        }
        Copy-Item -Path $tmpFrpc -Destination $exePath -Force
        Remove-Item $tmpFrpc -Force -ErrorAction SilentlyContinue
        Write-Host "  ✅ frpc.exe 已就绪:$exePath" -ForegroundColor Green
    }

    # 3) 写 frpc.toml(v0.61 格式;heartbeat 用 transport.* 不是顶层)
    $toml = @"
serverAddr = "$VpsHost"
serverPort = 7000
auth.token = "$FrpToken"

transport.heartbeatInterval = 10
transport.heartbeatTimeout = 30

# 链路 A: 反向 SSH (主人家里)
[[proxies]]
name = "home-ssh"
type = "tcp"
localIP = "127.0.0.1"
localPort = 22
remotePort = $FrpSshPort
transport.useCompression = true
"@
    [System.IO.File]::WriteAllText($tomlPath, $toml, [System.Text.UTF8Encoding]::new($false))
    Write-Host "  ✅ frpc.toml 已写(remotePort=$FrpSshPort)" -ForegroundColor Green

    # 4) 注册 frpc-bg 计划任务(BootTrigger + SYSTEM + RestartOnFailure)
    # frpc 退出非 0 → 任务判失败 → 1 min 后自动重启,最多 999 次(≈ 16 小时)
    Write-Host "  注册 frpc-bg 计划任务(BootTrigger + RestartOnFailure)..." -ForegroundColor Cyan
    $existing = Get-ScheduledTask frpc-bg -ErrorAction SilentlyContinue
    if ($existing) {
        Unregister-ScheduledTask -TaskName frpc-bg -Confirm:$false
    }

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
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
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
    Register-ScheduledTask -TaskName frpc-bg -Xml (Get-Content $tmpXml -Raw) -Force | Out-Null
    Remove-Item $tmpXml -Force -ErrorAction SilentlyContinue
    Write-Host "  ✅ frpc-bg 已注册" -ForegroundColor Green

    # 5) 触发启动 + 等 + 验证
    Write-Host "  触发 frpc-bg /Run + 等 6s..." -ForegroundColor Cyan
    schtasks /Run /TN frpc-bg 2>&1 | Out-Null
    Start-Sleep -Seconds 6
    $frpcProc = (tasklist /FI "IMAGENAME eq frpc.exe" /NH 2>$null) | Where-Object { $_ -match 'frpc\.exe' } | Select-Object -First 1
    if ($frpcProc -and $frpcProc -match 'frpc\.exe\s+(\d+)') {
        Write-Host "  ✅ frpc 启了 (PID $($Matches[1]))" -ForegroundColor Green
    } else {
        Write-Host "  ⚠️  frpc 暂未起,看 TaskScheduler Operational 日志" -ForegroundColor Yellow
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
    Write-Step "C3" "配置 PowerShell alias(wpc-* 一键 SSH)"
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
    # frpc:用 tasklist 跨 session 查(Session 0 NSSM/schtasks 起的 Get-Process 看不到)
    # 中文 win11 /NH 仍输出 header 行,Where-Object 过滤 frpc.exe 行(不靠 -First 1)
    $frpcLine = (tasklist /FI "IMAGENAME eq frpc.exe" /NH 2>$null) | Where-Object { $_ -match 'frpc\.exe' } | Select-Object -First 1
    $frpcTask = Get-ScheduledTask frpc-bg -ErrorAction SilentlyContinue
    if ($frpcLine -and $frpcLine -match 'frpc\.exe\s+(\d+)') {
        Write-Host "frpc: PID $($Matches[1]) running" -ForegroundColor Green
    } else {
        Write-Host "frpc: 未跑" -ForegroundColor Yellow
    }
    if ($frpcTask) {
        Write-Host "frpc plan task: frpc-bg ($($frpcTask.State))" -ForegroundColor Green
    } else {
        Write-Host "frpc plan task: 未注册" -ForegroundColor Yellow
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

    # 合并 Switch:重新拉 VPS 清单 + 重写 ~/.ssh/config + PowerShell alias
    # 拉到的清单即上方"--- VPS 注册主机 ---"段,顺手刷新本地配置
    Write-Host ""
    Write-Host "🔄 同步本地配置(按 VPS 清单重写 ~/.ssh/config + PowerShell alias)..." -ForegroundColor Cyan
    Generate-SSHConfigFromVPS
    Add-PowerShellAliases
    Write-Host "✅ 同步完成。PowerShell 重启后 alias 生效。" -ForegroundColor Green
}

# ---------- PreCheck: 环境体检报告(不改) ----------
function Invoke-PreCheck {
    Write-Host ""
    Write-Host "========== PreCheck ==========" -ForegroundColor Cyan

    # 主人 / 权限
    $isAdmin = [bool]([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Host "管理员: $(if ($isAdmin) { '✅' } else { '❌' })"

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Write-Host "OS:     $($os.Caption) Build $($os.BuildNumber)"
    } catch {}

    # 账号
    $u = $null
    if (-not $LocalUser) { $LocalUser = $DEFAULT_USER }
    try {
        $u = Get-LocalUser -Name $LocalUser -ErrorAction Stop
        Write-Host "账号:   $LocalUser $(if ($u.PasswordRequired) {'✅ 已设密码'} else {'⚠️  未设密码'})"
    } catch {
        Write-Host "账号:   $LocalUser ❌ 不存在"
    }

    # 网络(3 项各 ~3s, 同步跑)
    Write-Host ""
    Write-Host "网络:" -ForegroundColor DarkGray
    $ghOk    = (Test-NetConnection 'raw.githubusercontent.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) -eq $true
    $apiOk   = (Test-NetConnection $VpsHost -Port 8080 -InformationLevel Quiet -WarningAction SilentlyContinue) -eq $true
    $frpsOk  = (Test-NetConnection $VpsHost -Port 7000 -InformationLevel Quiet -WarningAction SilentlyContinue) -eq $true
    Write-Host "  GitHub raw (:443)    : $(if ($ghOk){'✅ 通'}else{'❌ 不通'})"
    Write-Host "  VPS ssh-deploy-api   : $(if ($apiOk){'✅ :8080 通'}else{'❌ :8080 不通'})"
    Write-Host "  VPS frps             : $(if ($frpsOk){'✅ :7000 通'}else{'❌ :7000 不通'})"

    # 环境软件
    Write-Host ""
    Write-Host "环境软件:" -ForegroundColor DarkGray
    $sshdExe  = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
    $sshExe   = "$env:SystemRoot\System32\OpenSSH\ssh.exe"
    $frpcExe  = Join-Path $FrpcInstallDir 'frpc.exe'
    $tomlOk   = Test-Path (Join-Path $FrpcInstallDir 'frpc.toml')
    Write-Host "  sshd:        $(if (Test-Path $sshdExe){'✅ 已装'}else{'❌ 未装'})"
    Write-Host "  ssh.exe:     $(if (Test-Path $sshExe){'✅ 已装'}else{'❌ 未装'})"
    Write-Host "  frpc.exe:    $(if (Test-Path $frpcExe){'✅ '+ $frpcExe}else{'❌ 未装'})"
    Write-Host "  frpc.toml:   $(if ($tomlOk){'✅ 已配置'}else{'❌ 未写'})"
    $frpcBgTask = Get-ScheduledTask frpc-bg -ErrorAction SilentlyContinue
    Write-Host "  frpc-bg:     $(if ($frpcBgTask){"✅ $($frpcBgTask.State)"}else{'❌ 未注册'})"
    $frpcProc = (tasklist /FI "IMAGENAME eq frpc.exe" /NH 2>$null) | Where-Object { $_ -match 'frpc\.exe' } | Select-Object -First 1
    Write-Host "  frpc 进程:   $(if ($frpcProc -and $frpcProc -match 'frpc\.exe\s+(\d+)'){"✅ PID $($Matches[1])"}else{'❌ 未跑'})"

    # 端口 / 防火墙
    Write-Host ""
    Write-Host "端口 / 防火墙:" -ForegroundColor DarkGray
    $conn22 = Get-NetTCPConnection -LocalPort 22 -State Listen -ErrorAction SilentlyContinue
    Write-Host "  :22 LISTEN:         $(if ($conn22){'✅'}else{'❌ 未监听'})"
    $fwRule = Get-NetFirewallRule -DisplayName 'OpenSSH-Server-In-TCP' -ErrorAction SilentlyContinue
    Write-Host "  防火墙 :22 放行:    $(if ($fwRule){'✅'}else{'❌ 未加'})"

    # ssh-deploy 痕迹(要清的)
    Write-Host ""
    Write-Host "ssh-deploy 痕迹:" -ForegroundColor DarkGray
    $oldFrpDir = 'C:\Tools\frp'
    Write-Host "  C:\Tools\frp (老):  $(if (Test-Path $oldFrpDir){'⚠️  存在,要清'}else{'✅ 无'})"
    $cfgContent = if (Test-Path $cfg) { Get-Content $cfg -Raw -ErrorAction SilentlyContinue } else { '' }
    Write-Host "  ~/.ssh/config 段:   $(if ($cfgContent -match '# ===== ssh-deploy:'){'⚠️  存在,要清'}else{'✅ 无'})"
    $profContent = if (Test-Path $PROFILE) { Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue } else { '' }
    Write-Host "  PROFILE alias 段:   $(if ($profContent -match '# ===== ssh-deploy aliases'){'⚠️  存在,要清'}else{'✅ 无'})"
    $oldAutostart = Get-ScheduledTask frpc-autostart -ErrorAction SilentlyContinue
    Write-Host "  frpc-autostart(老): $(if ($oldAutostart){'⚠️  存在,要清'}else{'✅ 无'})"

    # Defender
    Write-Host ""
    Write-Host "Defender:" -ForegroundColor DarkGray
    try {
        $def = Get-MpPreference -ErrorAction Stop
        Write-Host "  \$env:TEMP 排除:    $(if ($def.ExclusionPath -contains $env:TEMP){'✅ 已加'}else{'❌ 未加'})"
        Write-Host "  $FrpcInstallDir 排除: $(if ($def.ExclusionPath -contains $FrpcInstallDir){'✅ 已加'}else{'⚠️  未加'})"
    } catch {
        Write-Host "  (Defender 未启用 / 权限不足)"
    }

    Write-Host "==============================" -ForegroundColor Cyan
}

# ---------- PreCleanup: 清残留(不动环境软件) ----------
function Invoke-PreCleanup {
    Write-Host ""
    Write-Host "========== PreCleanup ==========" -ForegroundColor Cyan
    Write-Host "清:ssh-deploy 老路径 + 老 frpc-autostart + ssh-deploy 段 + Defender 加 C:\frp"
    Write-Host ""
    $confirm = Read-Host "确认清? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "❌ 取消 PreCleanup" -ForegroundColor Yellow
        return
    }

    # 1) 老 frp 路径
    if (Test-Path 'C:\Tools\frp') {
        Write-Host "  [1/5] 删 C:\Tools\frp ..." -ForegroundColor DarkGray
        try {
            Remove-Item 'C:\Tools\frp' -Recurse -Force -ErrorAction Stop
            Write-Host "    ✅ 已删"
        } catch {
            Write-Host "    ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [1/5] 删 C:\Tools\frp ...(不存在,跳过)"
    }

    # 2) 老 frpc-autostart 任务(老版本曾用此名)
    $oldTask = Get-ScheduledTask frpc-autostart -ErrorAction SilentlyContinue
    if ($oldTask) {
        Write-Host "  [2/5] 删 frpc-autostart 计划任务 ..." -ForegroundColor DarkGray
        try {
            Unregister-ScheduledTask -TaskName frpc-autostart -Confirm:$false -ErrorAction Stop
            Write-Host "    ✅ 已删"
        } catch {
            Write-Host "    ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [2/5] 删 frpc-autostart ...(不存在,跳过)"
    }

    # 3) ~/.ssh/config ssh-deploy 段
    if ((Test-Path $cfg) -and ((Get-Content $cfg -Raw -ErrorAction SilentlyContinue) -match '# ===== ssh-deploy:')) {
        Write-Host "  [3/5] 删 ~/.ssh/config ssh-deploy 段 ..." -ForegroundColor DarkGray
        try {
            $c = Get-Content $cfg -Raw -ErrorAction Stop
            $c = [regex]::Replace($c, '(?ms)# ===== ssh-deploy:.*?# ===== END ssh-deploy =====\r?\n?', '')
            [System.IO.File]::WriteAllText($cfg, $c, (New-Object System.Text.UTF8Encoding $false))
            Write-Host "    ✅ 已删"
        } catch {
            Write-Host "    ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [3/5] 删 ~/.ssh/config 段 ...(无,跳过)"
    }

    # 4) PROFILE alias 段
    if ((Test-Path $PROFILE) -and ((Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue) -match '# ===== ssh-deploy aliases')) {
        Write-Host "  [4/5] 删 PROFILE ssh-deploy alias 段 ..." -ForegroundColor DarkGray
        try {
            $p = Get-Content $PROFILE -Raw -ErrorAction Stop
            $p = [regex]::Replace($p, '(?ms)# ===== ssh-deploy aliases =====.*?# ===== END ssh-deploy aliases =====\r?\n?', '')
            [System.IO.File]::WriteAllText($PROFILE, $p, (New-Object System.Text.UTF8Encoding $false))
            Write-Host "    ✅ 已删"
        } catch {
            Write-Host "    ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  [4/5] 删 PROFILE alias 段 ...(无,跳过)"
    }

    # 5) Defender 排除加 C:\frp
    Write-Host "  [5/5] Defender 排除加 $FrpcInstallDir ..." -ForegroundColor DarkGray
    try {
        Add-MpPreference -ExclusionPath $FrpcInstallDir -ErrorAction Stop
        Write-Host "    ✅ 已加"
    } catch {
        Write-Host "    (Defender 未启用 / 已存在 / 权限不足)"
    }

    Write-Host "==============================" -ForegroundColor Cyan
}

# ---------- 主流程:Install (PreCheck + PreCleanup + 装) ----------
function Invoke-Install {
    Get-InstallParams

    # 阶段 A:PreCheck(报告,不改)
    Invoke-PreCheck

    # 阶段 B:PreCleanup(主人决定 yes/no)
    Invoke-PreCleanup

    # 阶段 C:装(server + client 融合,按 mode 切)
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
        Generate-SSHConfigFromVPS
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
    # 自动 register(有 Bearer 就调,失败不致命但提示)
    if ($BearerToken) {
        $regOk = Register-ThisHost
        if (-not $regOk) {
            Write-Host ""
            Write-Host "⚠️  本机未注册到 VPS。稍后重跑菜单 [3] 把本机登记到 VPS" -ForegroundColor Yellow
        }
    }
    Write-Host "============================================" -ForegroundColor Green
}

# ---------- Uninstall 本机 ----------
# 清所有 ssh-deploy 装过的东西:
#   - VPS 注销本机(可选)
#   - sshd 服务(停 + 禁自启 + 卸 capability)
#   - sshd 防火墙规则 :22
#   - frpc 进程 + schtasks frpc-autostart(若本脚本创的)
#   - C:\Tools\frp\(若本脚本创的)
#   - ~/.ssh/config 里 ssh-deploy 段
#   - PowerShell profile 里 wpc-* alias
#   - ssh-deploy 脚本本身不删(主人手动决定)
function Invoke-Uninstall {
    Write-Host ""
    Write-Host "========== Uninstall ssh-deploy ==========" -ForegroundColor Yellow
    Write-Host "本机将要清:"
    Write-Host "  - VPS hosts.json 本机条目(若有 Bearer)"
    Write-Host "  - sshd 服务(停 + 禁自启 + 卸 OpenSSH.Server capability)"
    Write-Host "  - 防火墙规则 :22 (sshd)"
    Write-Host "  - frpc 进程 + 计划任务 frpc-autostart(本脚本创的)"
    Write-Host "  - C:\Tools\frp\(本脚本创的 frpc 目录)"
    Write-Host "  - ~/.ssh/config 里 ssh-deploy 段"
    Write-Host "  - PowerShell profile 里 wpc-* alias"
    Write-Host ""
    $confirm = Read-Host "确认? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "❌ 取消" -ForegroundColor Yellow
        return
    }

    # 1) VPS 注销本机
    Write-Host ""
    Write-Host "[1/7] VPS 注销本机..." -ForegroundColor Cyan
    try {
        Unregister-ThisHost
    } catch {
        Write-Host "  跳过(失败不致命):$($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2) sshd 服务停 + 禁自启
    Write-Host ""
    Write-Host "[2/7] sshd 服务停 + 禁自启..." -ForegroundColor Cyan
    $svc = Get-Service sshd -ErrorAction SilentlyContinue
    if ($svc) {
        try {
            if ($svc.Status -eq 'Running') { Stop-Service sshd -Force -ErrorAction Stop }
            Set-Service sshd -StartupType Disabled -ErrorAction Stop
            Write-Host "  ✅ sshd 已停 + 禁自启" -ForegroundColor Green
        } catch {
            Write-Host "  ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  (sshd 未装)" -ForegroundColor DarkGray
    }

    # 3) 防火墙规则 :22
    Write-Host ""
    Write-Host "[3/7] 防火墙规则 :22..." -ForegroundColor Cyan
    try {
        Remove-NetFirewallRule -DisplayName 'ssh-deploy-sshd' -ErrorAction Stop
        Write-Host "  ✅ 防火墙规则已删" -ForegroundColor Green
    } catch {
        Write-Host "  (无 / 已删)" -ForegroundColor DarkGray
    }

    # 4) frpc 进程 + 计划任务(只清本脚本创的 frpc-autostart;不动主人的 frpc-bg)
    Write-Host ""
    Write-Host "[4/7] frpc 进程 + 计划任务 frpc-autostart..." -ForegroundColor Cyan
    $task = Get-ScheduledTask frpc-autostart -ErrorAction SilentlyContinue
    if ($task) {
        try {
            Unregister-ScheduledTask -TaskName frpc-autostart -Confirm:$false -ErrorAction Stop
            Write-Host "  ✅ 计划任务 frpc-autostart 已删" -ForegroundColor Green
        } catch {
            Write-Host "  ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  (无 frpc-autostart 任务)" -ForegroundColor DarkGray
    }
    # 杀 frpc 进程(由 schtasks 拉起的会随任务删自动停;手动启的兜底杀一次)
    $frpc = Get-Process frpc -ErrorAction SilentlyContinue
    if ($frpc) {
        try {
            $frpc | Stop-Process -Force -ErrorAction Stop
            Write-Host "  ✅ frpc 进程已杀" -ForegroundColor Green
        } catch {
            Write-Host "  ⚠️  杀 frpc 失败(权限?):$($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # 5) C:\Tools\frp\(本脚本创的 frpc 目录)
    Write-Host ""
    Write-Host "[5/7] C:\Tools\frp\..." -ForegroundColor Cyan
    if (Test-Path $FrpcInstallDir) {
        try {
            Remove-Item $FrpcInstallDir -Recurse -Force -ErrorAction Stop
            Write-Host "  ✅ 已删" -ForegroundColor Green
        } catch {
            Write-Host "  ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  (目录不存在)" -ForegroundColor DarkGray
    }

    # 6) ~/.ssh/config 里 ssh-deploy 段
    Write-Host ""
    Write-Host "[6/7] ~/.ssh/config ssh-deploy 段..." -ForegroundColor Cyan
    if (Test-Path $cfg) {
        $content = Get-Content $cfg -Raw -ErrorAction SilentlyContinue
        if ($content -match '# ===== ssh-deploy:') {
            try {
                $new = [regex]::Replace($content, '(?ms)# ===== ssh-deploy:.*?# ===== END ssh-deploy =====\r?\n?', '')
                [System.IO.File]::WriteAllText($cfg, $new, [System.Text.UTF8Encoding]::new($false))
                Write-Host "  ✅ ssh-deploy 段已删" -ForegroundColor Green
            } catch {
                Write-Host "  ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  (无 ssh-deploy 段)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  (config 不存在)" -ForegroundColor DarkGray
    }

    # 7) PowerShell profile wpc-* alias
    Write-Host ""
    Write-Host "[7/7] PowerShell profile wpc-* alias..." -ForegroundColor Cyan
    if (Test-Path $PROFILE) {
        $pc = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
        if ($pc -match 'ssh-deploy: wpc-') {
            try {
                $new = [regex]::Replace($pc, '(?ms)# ===== ssh-deploy:.*?# ===== END ssh-deploy =====\r?\n?', '')
                [System.IO.File]::WriteAllText($PROFILE, $new, [System.Text.UTF8Encoding]::new($false))
                Write-Host "  ✅ profile ssh-deploy 段已删" -ForegroundColor Green
            } catch {
                Write-Host "  ⚠️  失败:$($_.Exception.Message)" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  (无 ssh-deploy alias)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  (profile 不存在)" -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "============================================" -ForegroundColor Green
    Write-Host "✅ Uninstall 完成" -ForegroundColor Green
    Write-Host ""
    Write-Host "注意:本脚本本身未删,主人手动决定是否保留。" -ForegroundColor DarkGray
}


# ---------- Syncthing 协同层 ----------
$script:SyncthingConfigDir = Join-Path $env:LOCALAPPDATA 'Syncthing'
$script:SyncthingExe = Join-Path $script:SyncthingConfigDir 'syncthing.exe'
$script:SyncthingConfig = Join-Path $script:SyncthingConfigDir 'config.xml'
$script:SyncthingPoller = Join-Path $PSScriptRoot 'ssh-deploy-poller.ps1'
$script:SyncthingTaskName = 'ssh-deploy-poller'
$script:SyncthingDefaultVps = '8.163.106.31'

function Get-SyncthingInstallStatus {
    return [pscustomobject]@{
        Exe       = Test-Path $script:SyncthingExe
        Config    = Test-Path $script:SyncthingConfig
        Running   = ($null -ne (Get-Process syncthing -ErrorAction SilentlyContinue))
        Task      = ($null -ne (Get-ScheduledTask -TaskName $script:SyncthingTaskName -ErrorAction SilentlyContinue))
        AutoStart = (Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Syncthing.lnk'))
    }
}

function Get-BearerTokenLocal {
    $p = Join-Path $env:USERPROFILE '.ssh\deploy-secrets.md'
    if (-not (Test-Path $p)) { return $null }
    foreach ($line in Get-Content $p) {
        $t = $line.Trim()
        if ($t -match '^BEARER_TOKEN=(.+)$') {
            return ($Matches[1].Trim() -replace '^"', '' -replace '"$', '')
        }
    }
    return $null
}

function Get-DeviceIdFromSyncthing {
    if (-not (Test-Path $script:SyncthingConfig)) { return $null }
    try {
        $cfg = [xml](Get-Content $script:SyncthingConfig -Raw)
        # Syncthing 旧版根元素 <syncthing>, 新版 (>=1.x) 根元素 <configuration>
        if ($cfg.configuration.device.id) { return $cfg.configuration.device.id }
        if ($cfg.syncthing.device.id)    { return $cfg.syncthing.device.id }
        return $null
    } catch { return $null }
}

function Install-Syncthing {
    if (Test-Path $script:SyncthingExe) {
        Write-Host "Syncthing 已装: $script:SyncthingExe" -ForegroundColor DarkGray
        return $true
    }
    if (-not (Test-Path $script:SyncthingConfigDir)) {
        New-Item -ItemType Directory -Path $script:SyncthingConfigDir -Force | Out-Null
    }
    Write-Host "装 Syncthing (winget 优先 / MSI fallback)..." -ForegroundColor Cyan
    $ok = $false
    # 1) winget 优先
    try {
        $w = Get-Command winget -ErrorAction Stop
        Write-Host "winget 找到: $($w.Source)" -ForegroundColor DarkGray
        & winget install --id Syncthing.Syncthing -e --accept-package-agreements --accept-source-agreements --silent 2>&1 | Out-Host
        # winget 装好后会建 winget Links/ + 加 PATH, 用 where 找真实 exe
        $whereOut = (where.exe syncthing 2>&1 | Select-Object -First 1) -as [string]
        if ($whereOut -and (Test-Path $whereOut)) {
            Copy-Item $whereOut $script:SyncthingExe -Force
            $ok = $true
            Write-Host "winget 装到: $whereOut" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "winget 不可用: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    # 2) GitHub release fallback (最新稳定版 URL, latest redirect 自动跟)
    if (-not $ok) {
        Write-Host "走 GitHub release fallback..." -ForegroundColor Cyan
        $zip = Join-Path $env:TEMP 'syncthing.zip'
        try {
            $url = 'https://github.com/syncthing/syncthing/releases/latest/download/syncthing-windows-amd64.zip'
            Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
            Expand-Archive -Path $zip -DestinationPath $script:SyncthingConfigDir -Force
            $exe = Get-ChildItem (Join-Path $script:SyncthingConfigDir 'syncthing-windows-*') -Filter syncthing.exe -Recurse | Select-Object -First 1
            if ($exe) {
                Move-Item $exe.FullName $script:SyncthingExe -Force
                $ok = $true
            }
        } catch {
            Write-Host "GitHub fallback 失败: $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }
    }
    if ($ok) {
        Write-Host "Syncthing 装好: $script:SyncthingExe" -ForegroundColor Green
        if (-not (Test-Path $script:SyncthingConfig)) {
            Write-Host "首次跑生成 device id..." -ForegroundColor Cyan
            $p = Start-Process $script:SyncthingExe -NoNewWindow -PassThru
            Start-Sleep -Seconds 8
            Get-Process syncthing -ErrorAction SilentlyContinue | Stop-Process -Force
            if (Test-Path $script:SyncthingConfig) {
                Write-Host "config.xml 已生成" -ForegroundColor Green
            } else {
                Write-Host "config.xml 未生成" -ForegroundColor Yellow
            }
        }
    }
    return $ok
}

function Register-DeviceToVPS {
    $token = Get-BearerTokenLocal
    if (-not $token) {
        Write-Host "没 BEARER_TOKEN, 先菜单 [3] 注册本机到 VPS" -ForegroundColor Red
        return $false
    }
    $devId = Get-DeviceIdFromSyncthing
    if (-not $devId) {
        Write-Host "Syncthing 未装 / config.xml 无 device id" -ForegroundColor Red
        return $false
    }
    $deviceName = Read-Host "设备名 (英文短名, 如 wk-main / old-rig / lap-room)"
    if (-not $deviceName) { return $false }
    $frpcInfo = $null
    try {
        foreach ($line in Get-Content (Join-Path $env:USERPROFILE '.ssh\frpc.ini') -ErrorAction Stop) {
            if ($line -match '^remote_port\s*=\s*(\d+)') { $frpcInfo = @{ remote_port = [int]$Matches[1] } }
        }
    } catch {}
    if (-not $frpcInfo) {
        Write-Host "没找到 frpc remote_port" -ForegroundColor Yellow
    }
    $body = @{
        device_id    = $devId
        device_name  = $deviceName
        capabilities = @{
            sshd      = @{ user = $env:USERNAME }
            frpc      = $frpcInfo
            syncthing = @{ folders = @() }
        }
    } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/device/register" `
            -Method POST -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -Body $body -TimeoutSec 8 -ErrorAction Stop
        Write-Host "已注册: $($r.device_name)" -ForegroundColor Green
        return $true
    } catch {
        Write-Host "注册失败: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Start-LongPollerTask {
    if (-not (Test-Path $script:SyncthingPoller)) {
        Write-Host "找不到 poller: $script:SyncthingPoller" -ForegroundColor Red
        return $false
    }
    $token = Get-BearerTokenLocal
    if (-not $token) {
        Write-Host "没 BEARER_TOKEN" -ForegroundColor Red
        return $false
    }
    Get-ScheduledTask -TaskName $script:SyncthingTaskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -ExecutionPolicy Bypass -Window Hidden -File `"$($script:SyncthingPoller)`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $script:SyncthingTaskName `
        -Action $action -Trigger $trigger -Principal $principal -Settings $settings `
        -Description "ssh-deploy long-poller (Syncthing 协同 / ssh-config 同步)" | Out-Null
    Write-Host "已注册计划任务: $script:SyncthingTaskName" -ForegroundColor Green
    Start-ScheduledTask -TaskName $script:SyncthingTaskName
    Write-Host "已立即启动" -ForegroundColor Green
    return $true
}

function Add-SyncthingAutoStart {
    $shortcut = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup\Syncthing.lnk'
    if (Test-Path $shortcut) {
        Write-Host "Syncthing 开机自启已存在" -ForegroundColor DarkGray
        return
    }
    $ws = New-Object -ComObject WScript.Shell
    $s = $ws.CreateShortcut($shortcut)
    $s.TargetPath = $script:SyncthingExe
    $s.WorkingDirectory = $script:SyncthingConfigDir
    $s.WindowStyle = 7
    $s.Save()
    Write-Host "Syncthing 开机自启已加" -ForegroundColor Green
}

function Invoke-SyncthingMenu {
    while ($true) {
        Write-Host ""
        Write-Host "========== Syncthing 协同 =========" -ForegroundColor Cyan
        $st = Get-SyncthingInstallStatus
        $devId = Get-DeviceIdFromSyncthing
        Write-Host "  exe:       $(if ($st.Exe) {'OK'} else {'NO'})  $script:SyncthingExe"
        Write-Host "  config:    $(if ($st.Config) {'OK'} else {'NO'})  $script:SyncthingConfig"
        if ($devId) { Write-Host "  device id: $($devId)" } else { Write-Host "  device id: (未生成)" -ForegroundColor DarkGray }
        Write-Host "  running:   $(if ($st.Running) {'OK'} else {'NO'})"
        Write-Host "  长轮询任务: $(if ($st.Task) {'OK'} else {'NO'})"
        Write-Host "  开机自启:   $(if ($st.AutoStart) {'OK'} else {'NO'})"
        Write-Host ""
        Write-Host "  [1] 装 Syncthing"
        Write-Host "  [2] 把本机登记到 VPS"
        Write-Host "  [3] 启动后台 long-poller (计划任务)"
        Write-Host "  [4] 加 Syncthing 开机自启"
        Write-Host "  [5] 看 VPS 设备目录 + 共享"
        Write-Host "  [6] 创建共享文件夹"
        Write-Host "  [7] 加入共享文件夹"
        Write-Host "  [8] 退出共享"
        Write-Host "  [0] 返回主菜单"
        Write-Host "===================================" -ForegroundColor Cyan
        $c = Read-Host "选择 [0-8]"
        switch ($c) {
            '1' { [void](Install-Syncthing) }
            '2' { [void](Register-DeviceToVPS) }
            '3' { [void](Start-LongPollerTask) }
            '4' { Add-SyncthingAutoStart }
            '5' { Show-DeviceDirectory }
            '6' { Create-SharedFolder }
            '7' { Join-SharedFolder }
            '8' { Leave-SharedFolder }
            '0' { return }
            default { Write-Host "无效输入" -ForegroundColor Yellow }
        }
    }
}

function Show-DeviceDirectory {
    $token = Get-BearerTokenLocal
    if (-not $token) { Write-Host "没 BEARER_TOKEN" -ForegroundColor Red; return }
    try {
        $r = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/device/list" `
            -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8 -ErrorAction Stop
        Write-Host ""
        Write-Host "===== VPS 设备目录 =====" -ForegroundColor Cyan
        foreach ($d in $r.devices) {
            $frpc = if ($d.capabilities.frpc) { $d.capabilities.frpc.remote_port } else { '-' }
            $onl = if ($d.online) { 'online' } else { 'offline' }
            $idShort = $d.device_id.Substring(0, [Math]::Min(14, $d.device_id.Length))
            Write-Host ("  {0,-20} {1,-15} {2}  frpc:{3}" -f $d.device_name, $idShort, $onl, $frpc)
        }
        $r2 = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/shared/list" `
            -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8 -ErrorAction Stop
        Write-Host ""
        Write-Host "===== 共享文件夹 =====" -ForegroundColor Cyan
        foreach ($s in $r2.folders) {
            $mems = ($s.members | ForEach-Object { $_.device_id.Substring(0, 7) }) -join ', '
            Write-Host "  $($s.folder_id) - $($s.name) [members: $mems]"
        }
    } catch {
        Write-Host "拉取失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Create-SharedFolder {
    $token = Get-BearerTokenLocal
    if (-not $token) { Write-Host "没 BEARER_TOKEN" -ForegroundColor Red; return }
    $folderId = Read-Host "folder_id (英文短名)"
    $name = Read-Host "显示名 (回车用 folder_id)"
    if (-not $name) { $name = $folderId }
    $devId = Get-DeviceIdFromSyncthing
    $path = Read-Host "本机文件夹路径"
    if (-not $path) { return }
    try {
        $r = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/shared/create" `
            -Method POST -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -Body (@{ folder_id = $folderId; name = $name } | ConvertTo-Json -Compress) `
            -TimeoutSec 8 -ErrorAction Stop
        Write-Host "共享已创建: $($r.folder_id)" -ForegroundColor Green
        $r2 = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/shared/join" `
            -Method POST -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -Body (@{ device_id = $devId; folder_id = $folderId; folder_path = $path } | ConvertTo-Json -Compress) `
            -TimeoutSec 8 -ErrorAction Stop
        Write-Host "本机已加入, members: $($r2.members.Count)" -ForegroundColor Green
    } catch {
        Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Join-SharedFolder {
    $token = Get-BearerTokenLocal
    if (-not $token) { Write-Host "没 BEARER_TOKEN" -ForegroundColor Red; return }
    try {
        $r = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/shared/list" `
            -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8 -ErrorAction Stop
        Write-Host ""
        for ($i = 0; $i -lt $r.folders.Count; $i++) {
            $s = $r.folders[$i]
            Write-Host "  [$($i+1)] $($s.folder_id) - $($s.name) (members: $($s.members.Count))"
        }
        if ($r.folders.Count -eq 0) { Write-Host "(无共享)"; return }
        $idx = (Read-Host "选 [1-$($r.folders.Count)]") -as [int]
        if ($idx -lt 1 -or $idx -gt $r.folders.Count) { return }
        $target = $r.folders[$idx - 1]
        $path = Read-Host "本机文件夹路径"
        if (-not $path) { return }
        $devId = Get-DeviceIdFromSyncthing
        $r2 = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/shared/join" `
            -Method POST -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -Body (@{ device_id = $devId; folder_id = $target.folder_id; folder_path = $path } | ConvertTo-Json -Compress) `
            -TimeoutSec 8 -ErrorAction Stop
        Write-Host "已加入 $($target.folder_id)" -ForegroundColor Green
    } catch {
        Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Leave-SharedFolder {
    $token = Get-BearerTokenLocal
    if (-not $token) { Write-Host "没 BEARER_TOKEN" -ForegroundColor Red; return }
    try {
        $r = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/shared/list" `
            -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8 -ErrorAction Stop
        Write-Host ""
        $devId = Get-DeviceIdFromSyncthing
        for ($i = 0; $i -lt $r.folders.Count; $i++) {
            $s = $r.folders[$i]
            $onit = $s.members | Where-Object { $_.device_id -eq $devId }
            $marker = if ($onit) { '(本机在内)' } else { '' }
            Write-Host "  [$($i+1)] $($s.folder_id) $marker"
        }
        if ($r.folders.Count -eq 0) { Write-Host "(无共享)"; return }
        $idx = (Read-Host "选 [1-$($r.folders.Count)]") -as [int]
        if ($idx -lt 1 -or $idx -gt $r.folders.Count) { return }
        $target = $r.folders[$idx - 1]
        $r2 = Invoke-RestMethod -Uri "http://$($script:SyncthingDefaultVps):8080/shared/leave" `
            -Method POST -ContentType 'application/json' `
            -Headers @{ Authorization = "Bearer $token" } `
            -Body (@{ device_id = $devId; folder_id = $target.folder_id } | ConvertTo-Json -Compress) `
            -TimeoutSec 8 -ErrorAction Stop
        Write-Host "已退出 $($target.folder_id)" -ForegroundColor Green
    } catch {
        Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
    }
}
# ---------- 主菜单 ----------
function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "========== ssh-deploy ($env:COMPUTERNAME) =========" -ForegroundColor Cyan
        Write-Host "  [1] VPS 状态(云端所有主机 + 本机 sshd/frpc/port/config + 同步 alias)"
        Write-Host "  [2] Install 本机(PreCheck + PreCleanup + 装)"
        Write-Host "  [3] 把本机登记到 VPS"
        Write-Host "  [4] 注销主机(从 VPS 列表挑,本机 / 任意)"
        Write-Host "  [5] Uninstall 本机(清 sshd/frpc/schtasks/config/alias + VPS 注销)"
        Write-Host "  [7] PreCheck (环境体检报告,不改)"
        Write-Host "  [8] Syncthing 协同(装 + 接共享 + 后台 long-poller)"
        Write-Host "  [0] Exit"
        Write-Host "===========================================" -ForegroundColor Cyan
        $choice = Read-Host "选择 [0-8]"
        switch ($choice) {
            '1' { Show-Status }
            '2' { Invoke-Install }
            '3' { [void](Register-ThisHost) }
            '4' { [void](Unregister-Host) }
            '5' { Invoke-Uninstall }
            '7' { Invoke-PreCheck }
            '8' { Invoke-SyncthingMenu }
            '0' { return }
            default { Write-Host "无效输入" -ForegroundColor Yellow }
        }
    }
}

# ---------- 入口 ----------
if ($PSBoundParameters.Count -gt 0) {
    # 传参跑 → 直接 install(可脚本化)
    Invoke-Install
} else {
    Show-Menu
}