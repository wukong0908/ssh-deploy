# ssh-deploy

外机一键 SSH 连回本机的部署脚本,通过 FRP 内网穿透走云端 VPS。

## 架构

```
┌──────────────┐   SSH (公网 6000)   ┌──────────────┐   TCP (内网)   ┌──────────────┐
│  外机 Win/   │ ──────────────────► │ VPS          │ ──────────────► │ 本机 Win11   │
│  Android     │   走 FRPS 转发       │ 8.163.106.31 │   frpc         │ DESKTOP-WK   │
└──────────────┘                     │ 7000/6000    │                 │ sshd :22     │
                                     └──────────────┘                 └──────────────┘
```

- **VPS 上跑 FRPS**(frp server),开放 7000(控制) + 6000(SSH 转发)
- **本机跑 frpc**(frp client),把本机 22 端口映射到 VPS:6000
- **外机 SSH 客户端连 `8.163.106.31:6000`** → 经 FRPS 转发 → 本机 sshd

## 部署流程

### 本机(由 `host/setup-windows.ps1` 自动配)

| 步骤 | 动作 |
|---|---|
| OpenSSH Server | 优先从 WinSxS 离线拷(秒级),失败才走 Windows Update |
| sshd_config | `PasswordAuthentication yes` + 删 `Match Group administrators` 块 |
| 防火墙 | 22 端口入站放行 |
| frpc | 下载 0.61.1 + 写 `frpc.ini` + schtasks `frpc-autostart`(SYSTEM/AtLogOn) |
| 密码 | 检查 `WuKong` 账号 `PasswordRequired`,无则提示 `net user WuKong *` |

### 外机(由 `client/deploy-*` 自动配)

外机只需:**装 ssh client + 写 `~/.ssh/config` 段**。无密钥,密码认证。

## 快速运行命令

### 主机端(本机 Win11,首次配)

```powershell
# Step 1:管理员 PowerShell 设密码(必须先做)
net user WuKong *

# Step 2:跑一键部署(pinned commit hash 绕 CDN 缓存)
irm https://raw.githubusercontent.com/wukong0908/ssh-deploy/ade82fe/host/setup-windows.ps1 | iex
```

跑时交互(全回车,token 粘贴):

```
VPS 公网 IP 或域名(FRPS 所在) [8.163.106.31]:        ← 回车
FRPS token [回车=跳过 frpc 配置]:                     ← 粘贴 token
FRP SSH 转发端口 [6000]:                              ← 回车
本机 Win11 账号用户名 [WuKong]:                       ← 回车
```

跑完会显示:

```
[1/5] 检查 OpenSSH Server...
[2/5] 改 sshd_config(走 SYSTEM 任务绕 ACL)
[3/5] 放行 22
[4/5] frpc 配置 + 自启任务
[5/5] 主人账号密码检查 + sshd 重启
✅ 主机端部署完成!
  本机 sshd: Running
  FRP 入口: 8.163.106.31 :6000
```

### Windows 外机

```powershell
# 普通 PowerShell 即可(无需管理员)
irm https://raw.githubusercontent.com/wukong0908/ssh-deploy/7b9bf7e/client/deploy-windows.ps1 | iex
```

跑时交互:

```
VPS 公网 IP 或域名(FRPS 所在) [8.163.106.31]:        ← 回车
本机 Win11 的账号用户名 [WuKong]:                     ← 回车
FRP SSH 转发端口 [6000]:                              ← 回车
```

跑完:

```powershell
# 重开 PowerShell 让 alias 生效
ssh wukong-pc
# 或 alias:wpc
# 首次:输 yes → 输 Win11 密码 → 进 shell
```

### Android Termux

```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/4660158/client/deploy-android.sh | bash
```

非交互 stdin(`curl|bash`)走默认值 8.163.106.31:6000:WuKong。

跑完:

```bash
ssh wukong-pc
# 或 alias:wpc
# 首次:输 yes → 输 Win11 密码 → 进 shell
```

### CDN 缓存问题

GitHub raw 会缓存 master/main 分支,有时拉不到最新版。**解决方法**:用 commit hash 路径(见上)。跑完想拿最新版,直接换 hash。

## 验证

### 主机端

```powershell
Get-Service sshd                                # Running
Get-ScheduledTask -TaskName frpc-autostart       # Ready
Get-Process frpc                                 # PID 存在
Get-NetTCPConnection -LocalPort 22               # Listen
ssh WuKong@127.0.0.1                             # 输密码 → 进 shell
```

### VPS 端(frps 跑在 VPS 上)

```bash
systemctl status frps                            # active
# 日志应见 [ssh] proxy registered
```

### 外机端

```bash
ssh wukong-pc
# 输 yes(首次)+ Win11 密码 → 进 shell
```

## 文件

| 文件 | 用途 |
|---|---|
| `host/setup-windows.ps1` | 主主机侧一键配置(sshd + frpc + 自启) |
| `client/deploy-windows.ps1` | Win 外机一键部署(ssh client + config) |
| `client/deploy-android.sh` | Android Termux 一键部署 |

## 安全警告

1. **本仓库不包含任何私钥/密码/token** — 主人主动选密码认证,每端连时输密码
2. **首次运行会让你输入**:VPS IP、FRPS token、用户名 — 不入仓、不留痕
3. **FRPS token 由 SecureString 处理**,内存中明文不落盘(仅写入本机 `frpc.ini`)
4. **公开仓库红线**:即便主人要求也不上传私钥/密码/token
5. **主人公开 token 风险**:旧 token `18ec...dc1a` 已在本对话历史暴露,主人跑通后建议去 VPS 改新值

## 验证清单

跑完 `setup-windows.ps1` 后:

- [ ] `Get-Service sshd` → Running
- [ ] `Get-NetTCPConnection -LocalPort 22` → Listen
- [ ] `Get-Process frpc` → PID 存在
- [ ] `Get-ScheduledTask frpc-autostart` → Ready
- [ ] `ssh WuKong@127.0.0.1` → 输密码 → 进 shell
- [ ] VPS 端 `systemctl status frps` → 看到 `proxy [ssh]` 已注册
- [ ] 外机 `ssh wukong-pc` → 输 yes + 密码 → 进 shell