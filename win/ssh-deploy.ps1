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
    [string]$InstallMode = 'both',
    # 密钥文档路径(.env 风格 KEY=VALUE),外机部署由主人指定(u盘/网盘路径)
    [string]$TokenFile
)

# 启动计时(最先,任何慢操作之前)
$script:startTime = Get-Date

# 强制 TLS 1.2 — PS 5.1 默认 TLS 1.0,GitHub raw + frp release 都拒
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

# Defender 排除:OpenSSH zip 解压到 $TEMP,frpc.exe 是常见 PUA 检测目标
# 失败不致命(无 Defender / 已加 / 权限不足)
try {
    Add-MpPreference -ExclusionPath "$env:TEMP" -ErrorAction Stop
    Add-MpPreference -ExclusionPath "C:\Tools\frp" -ErrorAction Stop
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
$FrpcInstallDir = 'C:\frp'
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
        $url = "http://${VpsHost}:8080/ssh-deploy/hosts"
        $resp = Invoke-RestMethod -Uri $url -Headers (Get-VpsHeaders) -TimeoutSec 15 -ErrorAction Stop
        return $resp
    } catch {
        Write-Host "⚠️  拉 VPS hosts 失败:$($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Register-ThisHost {
    Get-RegisterParams
    if (-not $BearerToken) {
        Write-Host "需要 -BearerToken" -ForegroundColor Yellow
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
        $err = $_
        # 409 端口冲突:VPS API 返回 error.detail,告诉主人换端口
        if ($err.Exception.Response) {
            $code = [int]$err.Exception.Response.StatusCode
            if ($code -eq 409) {
                try {
                    $stream = $err.Exception.Response.GetResponseStream()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $body = $reader.ReadToEnd() | ConvertFrom-Json
                    Write-Host "❌ 端口冲突:$($body.detail)" -ForegroundColor Red
                    Write-Host "   解决:重跑 Install 时换 FRP SSH 转发端口(避免 6000/6001 等已被占用)" -ForegroundColor Yellow
                } catch {
                    Write-Host "❌ 端口冲突(409)" -ForegroundColor Red
                }
                return
            }
        }
        Write-Host "❌ register 失败:$($err.Exception.Message)" -ForegroundColor Red
    }
}

function Unregister-ThisHost {
    Get-RegisterParams
    if (-not $BearerToken) {
        Write-Host "需要 -BearerToken" -ForegroundColor Yellow
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

# ---------- 注销任意主机(从 VPS 列表挑) ----------
function Unregister-AnyHost {
    # 先拉 VPS 当前列表给主人看
    $hosts = Get-VpsHostsJson
    if (-not $hosts -or -not $hosts.servers -or $hosts.servers.Count -eq 0) {
        Write-Host "VPS 当前无主机注册" -ForegroundColor Yellow
        return
    }
    Write-Host ""
    Write-Host "--- VPS 当前注册主机 ---" -ForegroundColor Cyan
    $hosts.servers | ForEach-Object {
        Write-Host ("  {0,-20} port {1,-5} user {2}" -f $_.name, $_.ssh_port, $_.ssh_user)
    }
    Write-Host ""
    $target = Read-Host "输入要注销的主机名(name)"
    if (-not $target) {
        Write-Host "❌ 取消(空输入)" -ForegroundColor Yellow
        return
    }
    if (-not ($hosts.servers | Where-Object { $_.name -eq $target })) {
        Write-Host "❌ VPS 无此主机:$target" -ForegroundColor Red
        return
    }
    $confirm = Read-Host "确认注销 '$target'? (yes/no)"
    if ($confirm -ne 'yes') {
        Write-Host "❌ 取消" -ForegroundColor Yellow
        return
    }
    try {
        $url = "http://${VpsHost}:8080/ssh-deploy/unregister"
        $payload = @{ name = $target } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Uri $url -Method POST -ContentType 'application/json' -Headers (Get-VpsHeaders) -Body $payload -TimeoutSec 8 -ErrorAction Stop
        Write-Host "✅ 已注销 '$target'(移除 $($resp.removed) 条)" -ForegroundColor Green
    } catch {
        Write-Host "❌ unregister 失败:$($_.Exception.Message)" -ForegroundColor Red
    }
}

# ---------- helper: SSH config 生成 ----------
function Generate-SSHConfigFromVPS {
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
        $vps = if ($s.vps_host) { $s.vps_host } else { $VpsHost }
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
        # 当前已是管理员,直接同步跑 bat — 不走 schtasks /RU SYSTEM(老机器常禁 SeBatchLogonRight)
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
    # 当前已是管理员,直接同步跑 bat — 不走 schtasks /RU SYSTEM(老机器 LTSC 常禁 SeBatchLogonRight,导致 bat 永不启动 → log 不写)
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
    if (-not $frpcTask) {
        # 兼容 ssh-deploy 老版本自创的 frpc-autostart
        $frpcTask = Get-ScheduledTask frpc-autostart -ErrorAction SilentlyContinue
    }
    if ($frpcLine -and $frpcLine -match 'frpc\.exe\s+(\d+)') {
        Write-Host "frpc: PID $($Matches[1]) running" -ForegroundColor Green
    } else {
        Write-Host "frpc: 未跑" -ForegroundColor Yellow
    }
    if ($frpcTask) {
        $taskName = $frpcTask.TaskName
        Write-Host "frpc plan task: $taskName ($($frpcTask.State))" -ForegroundColor Green
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

# ---------- 主流程:Install ----------
function Invoke-Install {
    Get-InstallParams
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
    # 自动 register(有 Bearer 就调,失败不致命)
    if ($BearerToken) {
        Register-ThisHost
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

# ---------- 主菜单 ----------
function Show-Menu {
    while ($true) {
        Write-Host ""
        Write-Host "========== ssh-deploy ($env:COMPUTERNAME) =========" -ForegroundColor Cyan
        Write-Host "  [1] VPS 状态(云端所有主机 + 本机 sshd/frpc/port/config + 同步 alias)"
        Write-Host "  [2] Install 本机(server + client)"
        Write-Host "  [3] 把本机登记到 VPS"
        Write-Host "  [4] 从 VPS 注销本机"
        Write-Host "  [5] 从 VPS 注销任意主机"
        Write-Host "  [6] Uninstall 本机(清 sshd/frpc/schtasks/config/alias + VPS 注销)"
        Write-Host "  [0] Exit"
        Write-Host "===========================================" -ForegroundColor Cyan
        $choice = Read-Host "选择 [0-6]"
        # 兜底:任何不调 Get-*Params 的菜单项(1 VPS 状态)也能跑
        if (-not $script:VpsHost) { $script:VpsHost = $DEFAULT_VPS }
        switch ($choice) {
            '1' { Show-Status }
            '2' { Invoke-Install }
            '3' { Register-ThisHost }
            '4' { Unregister-ThisHost }
            '5' { Unregister-AnyHost }
            '6' { Invoke-Uninstall }
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