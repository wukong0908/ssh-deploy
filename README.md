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
| OpenSSH Server | `Add-WindowsCapability` 装 + 自动启动 |
| sshd_config | `PasswordAuthentication yes` + 删 `Match Group administrators` 块 |
| 防火墙 | 22 端口入站放行 |
| frpc | 下载 0.61.1 + 写 `frpc.ini` + schtasks `frpc-autostart`(SYSTEM/AtLogOn) |
| 密码 | 检查 `WuKong` 账号 `PasswordRequired`,无则提示 `net user WuKong *` |

### 外机(由 `client/deploy-*` 自动配)

外机只需:**装 ssh client + 写 `~/.ssh/config` 段**。无密钥,密码认证。

## 验证

### 主机端

```powershell
Get-Service sshd                                # Running
Get-ScheduledTask -TaskName frpc-autostart       # Ready
Get-Process frpc                                 # PID 存在
```

### 外机端

```bash
ssh wukong-pc
# 输 yes(首次) + Win11 密码 → 进 shell
```

## 使用

### 主机端(本机 Win11,首次配)

```powershell
# 管理员 PowerShell
irm https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/host/setup-windows.ps1 | iex
# 提示输入 VPS / FRPS token / SSH 转发端口(全有默认值,回车即可)
```

### Windows 外机

```powershell
irm https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/client/deploy-windows.ps1 | iex
# 提示输入 VPS / 端口 / 用户名(全有默认值)
```

### Android (Termux)

```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/client/deploy-android.sh | bash
# 非交互 stdin(curl|bash)走默认值,交互 stdin 提示输入
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

## 验证清单

跑完 `setup-windows.ps1` 后:

- [ ] `Get-Service sshd` → Running
- [ ] `Get-NetTCPConnection -LocalPort 22` → Listen
- [ ] `Get-Process frpc` → PID 存在
- [ ] `Get-ScheduledTask frpc-autostart` → Ready
- [ ] `ssh WuKong@127.0.0.1` → 输密码 → 进 shell
- [ ] VPS 端 `systemctl status frps` → 看到 `proxy [ssh]` 已注册
- [ ] 外机 `ssh wukong-pc` → 输 yes + 密码 → 进 shell