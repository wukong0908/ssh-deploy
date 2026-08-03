# ssh-deploy long-poller (后台跑)
# 通过 VPS /device/changes 长轮询, 收到变更 → 改 ~/.ssh/config + 写/改 Syncthing config.xml
#
# 入口: ssh-deploy.ps1 菜单 [8] → [7] 注册为 Task Scheduler 'ssh-deploy-poller' (登录后自启)
#       也可手跑: powershell -File ssh-deploy-poller.ps1

[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

$cfgPath = "$env:USERPROFILE\.ssh\config"
$syncthingConfig = Join-Path $env:LOCALAPPDATA 'Syncthing\config.xml'
$stateFile = Join-Path $env:LOCALAPPDATA 'Syncthing\.state.json'
$deviceIdFile = Join-Path $env:LOCALAPPDATA 'Syncthing\device-id.txt'
$defaultVps = '8.163.106.31'
$tokenCache = Join-Path $env:USERPROFILE '.ssh\deploy-secrets.md'

# ---------- helper ----------
function Get-BearerToken {
    if (-not (Test-Path $tokenCache)) { return $null }
    foreach ($line in Get-Content $tokenCache) {
        $t = $line.Trim()
        if ($t -match '^BEARER_TOKEN=(.+)$') {
            return $Matches[1].Trim() -replace '^"', '' -replace '"$', ''
        }
    }
    return $null
}

function Get-DeviceId {
    if (-not (Test-Path $syncthingConfig)) { return $null }
    try {
        $cfg = [xml](Get-Content $syncthingConfig -Raw)
        # Syncthing 旧版根元素 <syncthing>, 新版 (>=1.x) 根元素 <configuration>
        if ($cfg.configuration.device.id) { return $cfg.configuration.device.id }
        if ($cfg.syncthing.device.id)    { return $cfg.syncthing.device.id }
        return $null
    } catch { return $null }
}

function Get-State {
    if (Test-Path $stateFile) {
        try { return Get-Content $stateFile -Raw | ConvertFrom-Json } catch {}
    }
    return [pscustomobject]@{ last_ts = 0; processed = @{} }
}

function Save-State($s) {
    $s | ConvertTo-Json -Compress | Set-Content -Path $stateFile -Encoding utf8
}

function Update-SshConfig {
    # 收到 device 变更 → 重写 ~/.ssh/config ssh-deploy 段
    param([array]$Devices)
    if (-not $Devices) { return }
    # 确保目录
    $sshDir = Split-Path $cfgPath -Parent
    if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
    # 备份
    if (Test-Path $cfgPath) {
        $bak = "$cfgPath.bak.$(Get-Date -Format 'yyyyMMddHHmmss')"
        Copy-Item $cfgPath $bak -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType File -Path $cfgPath -Force | Out-Null
    }
    # 删旧 ssh-deploy 段
    $content = Get-Content $cfgPath -Raw -ErrorAction SilentlyContinue
    if ($content) {
        $content = [regex]::Replace($content, '(?ms)# ===== ssh-deploy:.*?# ===== END ssh-deploy =====\r?\n?', '')
        [System.IO.File]::WriteAllText($cfgPath, $content, (New-Object System.Text.UTF8Encoding $false))
    }
    # 写新段 (排除自己)
    $selfId = Get-DeviceId
    foreach ($d in $Devices) {
        if ($d.device_id -eq $selfId) { continue }
        $frpc = $d.capabilities.frpc
        if (-not $frpc) { continue }
        $alias = "wpc-$($d.device_name)"
        $segment = @"

# ===== ssh-deploy: $($d.device_name) =====
Host $alias
    HostName $defaultVps
    Port $($frpc.remote_port)
    User $($d.capabilities.sshd.user)
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
"@
        [System.IO.File]::AppendAllText($cfgPath, $segment, (New-Object System.Text.UTF8Encoding $false))
    }
    try { [System.IO.File]::SetAttributes($cfgPath, 'Hidden') } catch {}
}

function Update-SyncthingConfig {
    # 收到 device + shared 变更 → 改 Syncthing config.xml
    param([array]$Devices, [array]$Shared)
    if (-not (Test-Path $syncthingConfig)) { return }
    $cfg = [xml](Get-Content $syncthingConfig -Raw)
    # 新版 (>=1.x) 根元素 <configuration>, 老版 <syncthing>
    if ($cfg.configuration) { $root = $cfg.configuration }
    elseif ($cfg.syncthing) { $root = $cfg.syncthing }
    else { return }
    $selfId = (Get-DeviceId)

    # 设备列表 (排除自己)
    $validDeviceIds = @($selfId) + @($Devices | Where-Object { $_.device_id -ne $selfId } | ForEach-Object { $_.device_id })
    # 删多余 device 节点
    while ($root.device) {
        $node = $root.device
        $id = $node.id
        if ($validDeviceIds -notcontains $id) {
            $root.RemoveChild($node) | Out-Null
        } else {
            break
        }
    }
    # 加新 device
    foreach ($d in ($Devices | Where-Object { $_.device_id -ne $selfId })) {
        if ($cfg.SelectSingleNode("//device[@id='$($d.device_id)']")) { continue }
        $node = $cfg.CreateElement('device')
        $node.SetAttribute('id', $d.device_id)
        $node.SetAttribute('name', $d.device_name)
        $node.SetAttribute('compression', 'true')
        $node.SetAttribute('introducer', 'false')
        # addresses: 让 Syncthing 自己 announce + 走主人 VPS discovery
        $addr = $cfg.CreateElement('address')
        $addr.InnerText = 'dynamic'
        $node.AppendChild($addr)
        $root.AppendChild($node) | Out-Null
    }

    # folder
    $validFolderIds = @($Shared | ForEach-Object { $_.folder_id })
    # 删多余 folder
    foreach ($f in @($root.folder)) {
        if ($validFolderIds -notcontains $f.id) {
            $root.RemoveChild($f) | Out-Null
        }
    }
    # 加新 folder
    foreach ($s in $Shared) {
        if ($cfg.SelectSingleNode("//folder[@id='$($s.folder_id)']")) { continue }
        $member = $s.members | Where-Object { $_.device_id -eq $selfId } | Select-Object -First 1
        $folderPath = if ($member) { $member.folder_path } else { "D:\$($s.folder_id)" }
        $folder = $cfg.CreateElement('folder')
        $folder.SetAttribute('id', $s.folder_id)
        $folder.SetAttribute('label', $s.folder_id)
        $folder.SetAttribute('path', $folderPath)
        $folder.SetAttribute('type', 'sendreceive')
        # ignore .git
        $ign = $cfg.CreateElement('ignorePatterns')
        $ig1 = $cfg.CreateElement('pattern'); $ig1.InnerText = '//.git'; $ign.AppendChild($ig1)
        $ig2 = $cfg.CreateElement('pattern'); $ig2.InnerText = '//node_modules'; $ign.AppendChild($ig2)
        $ig3 = $cfg.CreateElement('pattern'); $ig3.InnerText = '//*.tmp'; $ign.AppendChild($ig3)
        $folder.AppendChild($ign)
        # 配所有 members 为 device
        foreach ($m in $s.members) {
            if ($m.device_id -eq $selfId) { continue }
            $dv = $cfg.CreateElement('device')
            $dv.SetAttribute('id', $m.device_id)
            $folder.AppendChild($dv)
        }
        $root.AppendChild($folder) | Out-Null
    }

    $cfg.Save($syncthingConfig)
}

function Restart-Syncthing {
    Get-Process syncthing -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $exe = Join-Path $env:LOCALAPPDATA 'Syncthing\syncthing.exe'
    if (Test-Path $exe) {
        Start-Process $exe -NoNewWindow
    }
}

# ---------- main loop ----------
$token = Get-BearerToken
if (-not $token) {
    Write-Host "❌ 没找到 BEARER_TOKEN 在 $tokenCache" -ForegroundColor Red
    exit 1
}
$selfId = Get-DeviceId
if (-not $selfId) {
    Write-Host "❌ Syncthing 未装 / config.xml 不存在" -ForegroundColor Red
    exit 1
}

Write-Host "[poller] 启, device_id=$selfId, vps=$defaultVps" -ForegroundColor Cyan
$state = Get-State

while ($true) {
    try {
        # 心跳
        $hbBody = @{ device_id = $selfId } | ConvertTo-Json -Compress
        try {
            Invoke-RestMethod -Uri "http://${defaultVps}:8080/device/heartbeat" -Method POST `
                -ContentType 'application/json' -Headers @{ Authorization = "Bearer $token" } `
                -Body $hbBody -TimeoutSec 5 -ErrorAction Stop | Out-Null
        } catch { Write-Host "[poller] 心跳失败:$($_.Exception.Message)" -ForegroundColor Yellow }

        # 长轮询变更
        $url = "http://${defaultVps}:8080/device/changes?since=$($state.last_ts)&wait=30"
        $resp = Invoke-RestMethod -Uri $url -Headers @{ Authorization = "Bearer $token" } `
            -TimeoutSec 40 -ErrorAction Stop

        if ($resp.changes -and $resp.changes.Count -gt 0) {
            Write-Host "[poller] 收到 $($resp.changes.Count) 条变更" -ForegroundColor Cyan
            # 重拉全量 (避免 partial 拼接)
            $dev = Invoke-RestMethod -Uri "http://${defaultVps}:8080/device/list" `
                -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8 -ErrorAction Stop
            $shr = Invoke-RestMethod -Uri "http://${defaultVps}:8080/shared/list" `
                -Headers @{ Authorization = "Bearer $token" } -TimeoutSec 8 -ErrorAction Stop
            Update-SshConfig -Devices $dev.devices
            Update-SyncthingConfig -Devices $dev.devices -Shared $shr.folders
            Restart-Syncthing
            $state.last_ts = $resp.ts
            Save-State($state)
        } else {
            # 长轮询 hold 30s 正常返空 → 继续下一轮
        }
    } catch {
        Write-Host "[poller] 错:$($_.Exception.Message)" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}