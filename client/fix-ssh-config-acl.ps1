[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# 1. 删 .ssh 重建
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (Test-Path $sshDir) {
    Remove-Item $sshDir -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path $sshDir -Force | Out-Null

# 2. 显式 owner + ACL
$me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
icacls $sshDir /inheritance:r /grant:r "${me}:(F)" "SYSTEM:(F)" 2>&1 | Out-Null
icacls $sshDir /setowner "$me" 2>&1 | Out-Null

# 3. 写最小 config
$cfg = Join-Path $sshDir "config"
@"
Host wpc-desktop-wk
  HostName 8.163.106.31
  Port 6000
  User wukong
  ServerAliveInterval 30
"@ | Out-File -FilePath $cfg -Encoding ascii -NoNewline

# 4. config 也锁
icacls $cfg /inheritance:r /grant:r "${me}:(F)" "SYSTEM:(F)" 2>&1 | Out-Null
icacls $cfg /setowner "$me" 2>&1 | Out-Null

# 5. known_hosts 同样处理 (空 ACL 会让 ssh 报 Permission denied)
$kh = Join-Path $sshDir "known_hosts"
if (Test-Path $kh) { Remove-Item $kh -Force -ErrorAction SilentlyContinue }
New-Item -ItemType File -Path $kh -Force | Out-Null
icacls $kh /inheritance:r /grant:r "${me}:(F)" "SYSTEM:(F)" 2>&1 | Out-Null
icacls $kh /setowner "$me" 2>&1 | Out-Null

Write-Host "ok"
Get-Content $cfg
& icacls.exe $cfg
& icacls.exe $kh