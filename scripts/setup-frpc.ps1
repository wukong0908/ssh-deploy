<#
.SYNOPSIS
    本机 frpc 客户端安装与注册为 Windows 服务,使其开机自启并连到 VPS 上的 frps。

.DESCRIPTION
    一次性脚本:
      1. 下载 frpc.exe(若已放好可跳过)
      2. 写 frpc.ini(server_addr=8.163.106.31, server_port=7000, 映射本机 22 → VPS 6000)
      3. 注册为 Windows 服务,设为自动启动

.NOTES
    frp token 必须与 VPS 上 frps.ini 一致。
    先把 token 写到环境变量 FRP_TOKEN,或修改脚本里的 $Token 字段。
#>

[CmdletBinding()]
param(
    [string]$FrpcDir = "C:\Tools\frp",
    [string]$FrpcVersion = "0.61.1",
    [string]$FrpsHost = "8.163.106.31",
    [int]$ControlPort = 7000,
    [int]$SshRemotePort = 6000,
    [string]$Token = $env:FRP_TOKEN
)

$ErrorActionPreference = 'Stop'

if (-not $Token) {
    Write-Error "未设置 frp token。请先:`$env:FRP_TOKEN='your_token'; 然后再跑本脚本。"
}

if (-not (Test-Path $FrpcDir)) { New-Item -ItemType Directory -Path $FrpcDir -Force | Out-Null }

# ---------- 下载 frpc.exe ----------
$exePath = Join-Path $FrpcDir "frpc.exe"
if (-not (Test-Path $exePath)) {
    Write-Host "下载 frpc $FrpcVersion..."
    $url = "https://github.com/fatedier/frp/releases/download/v$FrpcVersion/frp_${FrpcVersion}_windows_amd64.zip"
    $zip = Join-Path $env:TEMP "frpc.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $FrpcDir -Force
    # 解压后会有嵌套目录,挪平
    $nested = Get-ChildItem -Path $FrpcDir -Directory | Where-Object { $_.Name -like "frp_*" } | Select-Object -First 1
    if ($nested) {
        Get-ChildItem -Path $nested.FullName -File | Move-Item -Destination $FrpcDir -Force
        Remove-Item $nested.FullName -Recurse -Force
    }
    Remove-Item $zip -Force
}

# ---------- 写 frpc.ini ----------
$iniPath = Join-Path $FrpcDir "frpc.ini"
@"
[common]
server_addr = $FrpsHost
server_port = $ControlPort
token = $Token

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = $SshRemotePort
"@ | Set-Content -Path $iniPath -Encoding UTF8
Write-Host "已写 $iniPath"

# ---------- 注册 Windows 服务 ----------
$svcName = "frpc"
$existing = Get-Service -Name $svcName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "服务 $svcName 已存在,跳过注册"
} else {
    & "$FrpcDir\frpc.exe" service install -c "$iniPath" | Write-Host
    & "$FrpcDir\frpc.exe" service start | Write-Host
    Start-Sleep -Seconds 2
}

Get-Service -Name $svcName -ErrorAction SilentlyContinue | Format-List Name, Status, StartType
Write-Host "frpc 已就绪。外机可执行: ssh -p $SshRemotePort -i ~/.ssh/id_ed25519 WuKong@$FrpsHost"