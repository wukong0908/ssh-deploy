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

### 本机(已完成)

| 步骤 | 状态 |
|---|---|
| OpenSSH sshd 服务 | ✅ Running |
| 22 端口监听 | ✅ LISTEN |
| 防火墙规则 | ✅ Enabled |
| 用户 `~/.ssh/authorized_keys` | ✅ 公钥已写入 |
| frpc 客户端配置 | ❓ 需配置 |
| frpc 进程常驻 | ❓ 需启动 |

### 外机(本仓库目的)

外机只需:**装 ssh client + 配置 `~/.ssh/config` + 放好私钥**。

仓库不含私钥。私钥从本机导出后通过你信任的渠道传给外机。

## 使用

### 主机端(本机 Win11,首次配)

```powershell
# 管理员 PowerShell
irm https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/host/setup-windows.ps1 | iex
# 提示输入 VPS / FRPS token / SSH 转发端口
```

### Windows 外机

```powershell
irm https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/client/deploy-windows.ps1 | iex
# 提示输入 VPS / 用户名
```

### Android (Termux)

```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/client/deploy-android.sh | bash
```

## 文件

| 文件 | 用途 |
|---|---|
| `host/setup-windows.ps1` | 主主机侧一键配置(sshd + frpc) |
| `client/deploy-windows.ps1` | Win 外机一键部署 |
| `client/deploy-android.sh` | Android Termux 一键部署 |

## 安全警告

1. **本仓库不包含任何私钥/密码** — 主人主动选密码认证,每端连时输密码
2. **首次运行会让你输入**:VPS IP、FRPS token、用户名 — 不入仓、不留痕
3. **VPS root 密码 / frp token 由主人在 prompt 输入**,SecureString 处理,内存中明文不落盘