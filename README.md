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

### Windows

```powershell
# 远程一行(需先 git clone 或直接拉文件)
git clone <repo-url> ssh-deploy
.\ssh-deploy\client\deploy-windows.ps1
```

### Android (Termux)

```bash
pkg install openssh git
git clone <repo-url> ssh-deploy
bash ssh-deploy/client/deploy-android.sh
```

## 文件

| 文件 | 用途 |
|---|---|
| `client/deploy-windows.ps1` | Win 一键部署脚本 |
| `client/deploy-android.sh` | Android Termux 一键脚本 |
| `client/ssh_config.template` | SSH config 模板 |
| `docs/NETWORK.md` | 网络架构详图 |
| `docs/FRP_SETUP.md` | FRP 服务端/客户端配置 |
| `scripts/setup-frpc.ps1` | 本机 frpc 客户端启动脚本 |

## 安全警告

1. **本仓库不包含任何私钥/密码** — 私钥请自行通过安全渠道分发
2. **首次运行会让你输入**:VPS IP、SSH 用户名、私钥文件路径
3. **不要把私钥 push 到仓库** — `.gitignore` 已默认忽略,如有违规 push 立即轮换密钥