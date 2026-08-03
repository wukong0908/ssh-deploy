# Win 部署

主脚本 `windows/ssh-deploy.ps1`,Win11 默认双向(server + client)。

## 下载

```powershell
$tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/windows/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
```

要 pinned commit:
```powershell
Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/windows/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
```

## 主菜单

```
========== ssh-deploy (DESKTOP-WK) =========
  [1] VPS 状态(云端所有主机 + 本机 sshd/frpc/port/config + 同步 alias)
  [2] Install 本机(PreCheck + PreCleanup + 装)
  [3] 把本机登记到 VPS
  [4] 注销主机(从 VPS 列表挑,本机 / 任意)
  [5] Uninstall 本机(清 sshd/frpc/schtasks/config/alias + VPS 注销)
  [7] PreCheck (环境体检报告,不改)
  [8] Syncthing 协同(装 + 接共享 + 后台 long-poller)
  [0] Exit
```

## Install 三段流程

| 阶段 | 函数 | 行为 |
|---|---|---|
| A. PreCheck | `Invoke-PreCheck` | 体检报告(管理员/OS/账号/网络/环境软件/端口/痕迹/Defender),不改 |
| B. PreCleanup | `Invoke-PreCleanup` | 清老路径 `C:\Tools\frp` / 老 `frpc-autostart` 任务 / `~/.ssh/config` ssh-deploy 段 / PROFILE alias 段 / 加 Defender 排除 `C:\frp`。主人 `yes/no` 决定 |
| C. Install | `Invoke-Install` | 按 `InstallMode` 跑 server (sshd/sshd_config/防火墙/frpc-bg/账号检查) + client (ssh.exe/拉清单/写 config/写 alias) + 自动 register |

## Bearer token 落点

`~/.ssh/deploy-secrets.md`,权限 icacls 限当前用户 + SYSTEM。`BEARER_TOKEN=...` + `FRP_TOKEN=...` 两行。
首次跑要求提供 token 文档路径;之后从默认位置读。

## frpc-bg 计划任务

`Install-Frpc` 注册 `schtasks /Create /TN frpc-bg`(BootTrigger + SYSTEM + RestartOnFailure 1min×999)。
frpc 退出非 0 → 任务自动重启,无需 NSSM / WinSW。

## poller 后台

`windows/ssh-deploy-poller.ps1` 走 `ssh-deploy-poller` 计划任务(AtLogOn,登录后自启)。
主循环:
1. 心跳 /device/heartbeat (30s/次)
2. 长轮询 /device/changes?since=&wait=30
3. 收到变更 → 重拉全量 → 改 ~/.ssh/config ssh-deploy 段 → 改 Syncthing config.xml → Restart-Syncthing → Save-State

## 离线 OpenSSH(Win11 必看)

装脚本三级优先级,避免 Windows Update CDN 拖 30 分钟:
1. 仓内 zip `bin/openssh/OpenSSH-Win64.zip`(4.8MB,微软 v9.5.0)
2. 本机 WinSxS
3. Windows Update CDN 兜底

## 验证

```powershell
Get-Service sshd                                          # Running
Get-NetTCPConnection -LocalPort 22 -State Listen          # OK
Get-ScheduledTask frpc-bg                                 # Ready
ssh wpc-home                                              # 进主人机
```