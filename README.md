# ssh-deploy

> **多主机 + 多服务端注册中心** — 一脚本双向部署,客户端从 VPS 拉清单,SSH alias 多段自动生成.

旧版本三脚本(client/deploy-* + host/setup-*)仍兼容,继续用 → 见 [旧版本命令](#旧版本兼容).

## 架构

```
                   VPS 8.163.106.31
                   ┌──────────────────────┐
                   │ frps :7000 / :6000+  │ ← FRP 中转
                   │ ssh-deploy-api :8080 │ ← Bearer token 鉴权
                   │ hosts.json           │ ← 多服务端注册清单
                   └──────────┬───────────┘
                              │ HTTP GET/POST
       ┌──────────────────────┼──────────────────────┐
       │                      │                      │
   Win 主机 A             Win 主机 B            客户端(Win/Termux)
   DESKTOP-WK              DESKTOP-DEV
   Account: WuKong         Account: wukong
   sshd:22                 sshd:22
   frpc proxy 6000         frpc proxy 6001
```

**Win 一脚本 = 双向**(默认):同一台机既当服务端(别人 SSH 进),又当客户端(主动 SSH 出).**Termux 只客户端**.

## 关键概念

| 名词 | 含义 |
|---|---|
| **VPS** | `8.163.106.31`,跑 frps(:7000 + :6000+)和 ssh-deploy-api(:8080). 单一权威源 |
| **hosts.json** | VPS 上 `/var/lib/ssh-deploy/hosts.json`,存所有服务端条目(name/port/user/alias) |
| **Bearer token** | 主人 VPS 上自定的共享密码(防路人). **所有客户端/服务端同一值** |
| **ServerName** | VPS 注册名,默认 = `$env:COMPUTERNAME` 小写(Win)或 hostname |
| **alias** | SSH config 里的 `Host` 段名,默认 `wpc-<name>`,例:`wpc-home` / `wpc-dev` |
| **SSH User** | Win 账号,SSH 协议**严格大小写**:`WuKong`(主人机)/ `wukong`(老机器) |

## 三种使用场景

### 场景 1:装第一台主机(本机 Win11)

```powershell
# PS 7+ 不认 `irm | iex`,走下载 + 调两步
$tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/win/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
```

跑时:
1. 选 `[2] Install 本机`(PreCheck + PreCleanup + 装)
2. 提示输入:VPS / Bearer token / FRP token / 端口 / 本机账号 → 全有默认
3. 装完显示:本机 sshd Running + frpc PID + 端口 6000
4. 末了 register 到 VPS → hosts.json +1 条

### 场景 2:装第二台主机(老机器,账号 wukong)

```powershell
$tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/win/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
```

跑时:
1. 选 `[2] Install 本机`
2. **关键参数**:本机账号输 `wukong`(小写),FRP 端口输 `6001`,ServerName 输 `dev`
3. 装完:VPS hosts.json +1(`wpc-dev` → `wukong@8.163.106.31:6001`)
4. **任何已装客户端**重跑 `[1] VPS 状态` → 自动同步 `wpc-dev` alias

### 场景 3:装外机/客户端(Win 或 Termux)

**Win**:
```powershell
$tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/win/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp -InstallMode client
```

**Termux**:
```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/termux/ssh-deploy.sh | bash -s -- -v 8.163.106.31 -t YOUR_TOKEN
```

跑完自动:
- 装 OpenSSH Client
- 拉 VPS 主机清单
- 写 `~/.ssh/config` 多 `Host wpc-*` 段
- 写 PowerShell profile / bashrc alias(`wpc-home` 一键 SSH)

立刻可用:
```bash
ssh wpc-home   # 进主人机
ssh wpc-dev    # 进老机器
```

## 主菜单(Win 脚本)

```
========== ssh-deploy (DESKTOP-WK) =========
  [1] VPS 状态(云端所有主机 + 本机 sshd/frpc/port/config + 同步 alias)
  [2] Install 本机(PreCheck + PreCleanup + 装)
  [3] 把本机登记到 VPS
  [4] 注销主机(从 VPS 列表挑,本机 / 任意)
  [5] Uninstall 本机(清 sshd/frpc/schtasks/config/alias + VPS 注销)
  [7] PreCheck (环境体检报告,不改)
  [0] Exit
==========================================
```

### Install 三段流程

| 阶段 | 函数 | 行为 |
|---|---|---|
| A. PreCheck | `Invoke-PreCheck` | 体检报告(管理员/OS/账号/网络/环境软件/端口/痕迹/Defender). 不修改 |
| B. PreCleanup | `Invoke-PreCleanup` | 清老路径 `C:\Tools\frp` / 老 `frpc-autostart` 任务 / `~/.ssh/config` ssh-deploy 段 / PROFILE alias 段 / 加 Defender 排除 `C:\frp`. 主人 `yes/no` 决定 |
| C. Install | `Invoke-Install` | 按 `InstallMode` 跑 server (sshd/sshd_config/防火墙/frpc/账号检查) + client (ssh.exe/拉清单/写 config/写 alias) + 自动 register |

**Status 例子**:
```
========== ssh-deploy Status ==========
主机名: DESKTOP-WK
VPS:    8.163.106.31

sshd: Running / Automatic       ← 服务端
ssh.exe: C:\Windows\System32\OpenSSH\ssh.exe
frpc: PID 1234 running          ← frpc 转发 22→6000
frpc plan task: frpc-bg (Ready)
port 22: LISTEN

--- VPS 注册主机 ---
  home         port 6000   user WuKong       alias wpc-home
  dev          port 6001   user wukong       alias wpc-dev

--- ~/.ssh/config (wpc-* 段) ---
  Host wpc-home
  Host wpc-dev
=========================================
```

## Bearer Token 说明

| 项 | 值 |
|---|---|
| 是什么 | 主人 VPS 上自定字符串,例:`wukong_ssh_2026_secret_xxx` |
| 作用 | 鉴权 `http://VPS:8080/ssh-deploy/*` 所有 endpoints |
| 强度 | **只防路人**;真正安全靠 VPS 上换值 |
| 公开仓库风险 | `wukong0908/ssh-deploy` 是**公开**仓,**token 写入仓 = 公开** |
| 主人的做法 | token 不入仓;只在 VPS 的 `/etc/ssh-deploy/ssh-deploy.env` 存;客户端跑时手动输入 |

**主人 VPS 上生成 token**:
```bash
openssl rand -hex 16    # 例:e8a3...d4b2
# 写进 /etc/ssh-deploy/ssh-deploy.env,systemctl restart ssh-deploy-api
```

## VPS API 速查

| Endpoint | 方法 | 鉴权 | 作用 |
|---|---|---|---|
| `/healthz` | GET | 否 | 健康检查 |
| `/ssh-deploy/hosts` | GET | Bearer | 拉清单 |
| `/ssh-deploy/register` | POST | Bearer | 注册(`{name, vps_host, ssh_port, ssh_user, ...}`) |
| `/ssh-deploy/unregister` | POST | Bearer | 删(`{name}`) |

详见 [vps/INSTALL.md](vps/INSTALL.md) + [docs/JSON_SCHEMA.md](docs/JSON_SCHEMA.md).

## 客户端生成 SSH config 示例

VPS 返回:
```json
{
  "version": "1.0",
  "servers": [
    {"name": "home", "ssh_port": 6000, "ssh_user": "WuKong", "alias": "wpc-home"},
    {"name": "dev",  "ssh_port": 6001, "ssh_user": "wukong", "alias": "wpc-dev"}
  ]
}
```

自动写到 `~/.ssh/config`:
```sshconfig
# ===== ssh-deploy: home =====
Host wpc-home
    HostName 8.163.106.31
    Port 6000
    User WuKong
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====

# ===== ssh-deploy: dev =====
Host wpc-dev
    HostName 8.163.106.31
    Port 6001
    User wukong
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
```

**`User` 字段大小写由 JSON 控制**,主人机 = `WuKong`,老机器 = `wukong`. **不用主人手记**.

## 离线 OpenSSH(必看)

装脚本走**三级优先级**,**不再被 Windows Update CDN 拖到 30 分钟**:

1. **仓内 zip**(`bin/openssh/OpenSSH-Win64.zip`,4.8 MB,微软 v9.5.0)
2. **本机 WinSxS**(`C:\Windows\WinSxS\amd64_openssh-*-components-onecore_*`)
3. **Windows Update CDN**(5 ~ 30 分钟,兜底)

| 路径 | 时间 |
|---|---|
| 仓内 zip | ~10 秒 |
| WinSxS | ~5 秒 |
| Windows Update | 5 ~ 30 分钟 |

`Invoke-WebRequest` 跑时,自动从 `raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/openssh/OpenSSH-Win64.zip` 拉 5MB zip。

## 文件

| 文件 | 用途 |
|---|---|
| `win/ssh-deploy.ps1` | **Win 主入口**(默认双向:server + client) |
| `termux/ssh-deploy.sh` | **Termux 主入口**(只客户端) |
| `bin/openssh/OpenSSH-Win64.zip` | 微软 Win32-OpenSSH v9.5.0 离线包(4.8 MB) |
| `bin/openssh/README.md` | 离线包来源 + 重生成 SOP |
| `vps/ssh-deploy-api/server.py` | VPS API(Python 3 stdlib) |
| `vps/nginx-ssh-deploy.conf` | nginx 反代 + Bearer token 鉴权 |
| `vps/ssh-deploy-api.service` | systemd unit |
| `vps/INSTALL.md` | VPS 部署 SOP(8 步 + 故障排查) |
| `vps/hosts.json.example` | hosts.json 示例 |
| `docs/JSON_SCHEMA.md` | JSON 字段定义 |
| `docs/ARCHITECTURE.md` | (TBD) 详细架构图 |
| `docs/DEPLOY.md` | (TBD) 多主机部署指南 |

## 快速命令(pinned commit)

**Win 双向(本机)**:
```powershell
$tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/win/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
```

**Win 只客户端(外机)**:
```powershell
$tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/win/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp -InstallMode client
```

**Termux 客户端**:
```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/termux/ssh-deploy.sh | bash -s -- -v 8.163.106.31 -t YOUR_TOKEN
```

`<commit>` 用 `main` 也行,但可能被 GitHub raw 缓存拖后;**用 commit hash 保证拿到最新版**.

## 旧版本(已删除)

v1 单主机版 `host/setup-windows.ps1` + `client/deploy-windows.ps1` + `client/deploy-android.sh` **已于 2026-07-31 删库**.

需要查老版本:git 历史 `git log -- host/setup-windows.ps1`,checkout 到 commit `0857267` 之前.

新部署**只用**:
- Win: `win/ssh-deploy.ps1`
- Termux: `termux/ssh-deploy.sh`

## 安全警告

1. **本仓库不包含任何私钥 / 密码 / token**
2. **Bearer token 由主人手动管理**,不入仓
3. **公开仓库红线**:即便主人要求也不上传私钥 / 密码 / token
4. **老 token 风险**:旧 `18ec...dc1a` 已在本对话历史暴露,主人跑通后建议去 VPS 改新值

## 验证清单

### 主主机(Win)
- [ ] `Get-Service sshd` → Running
- [ ] `Get-NetTCPConnection -LocalPort 22` → Listen
- [ ] `Get-Process frpc` → PID 存在
- [ ] `Get-ScheduledTask frpc-bg` → Ready
- [ ] `ssh <user>@127.0.0.1` → 输密码 → 进 shell
- [ ] VPS hosts.json 有本机条目:`curl -H "Authorization: Bearer $TOKEN" http://8.163.106.31:8080/ssh-deploy/hosts | jq`

### 客户端(任意)
- [ ] `ssh wpc-home` → 输密码 → 进主人机
- [ ] `ssh wpc-dev` → 输密码 → 进老机器(若装过)
- [ ] `~/.ssh/config` 有多 Host wpc-* 段
- [ ] `wpc-home` alias 可用(PowerShell 重启后 / `source ~/.bashrc`)