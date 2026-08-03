# ssh-deploy

多主机反向 SSH 部署 + 设备目录同步,单一 VPS 权威源。

> v2 (2026-08-03 重塑)。设备目录走 `/device/*` + per-host token 双层鉴权;共享文件夹走 `/shared/*`;nginx :8080 反代,systemd hardening。

## 快速命令

**Win 双向(本机)**:
```powershell
$tmp = "$env:TEMP\ssh-deploy.ps1"; Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/windows/ssh-deploy.ps1' -OutFile $tmp -UseBasicParsing; & $tmp
```

**Win 只客户端(外机)**:
```powershell
& $tmp -InstallMode client
```

**Termux 客户端**:
```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/termux/ssh-deploy.sh | bash -s -- -v 8.163.106.31 -t YOUR_TOKEN
```

## 安全红线

- ❌ 任何私钥 / PAT / 密码 / Bearer token **不入仓**
- ❌ 不读 / 不 cat 任何密钥内容
- ✅ token / 密钥 路径是字符串,工具链直接传
- 详情: `~/.claude/CLAUDE.md` 全局约定

## 文档导航

| 文档 | 内容 |
|---|---|
| [docs/architecture.md](docs/architecture.md) | 架构图 + 数据流 + 心跳 + 长轮询时序 |
| [docs/api.md](docs/api.md) | REST 端点完整参考 |
| [docs/json-schema.md](docs/json-schema.md) | devices.json / shared.json 字段 |
| [docs/deploy-vps.md](docs/deploy-vps.md) | VPS 部署 SOP |
| [docs/deploy-windows.md](docs/deploy-windows.md) | Win 脚本使用 |
| [docs/deploy-termux.md](docs/deploy-termux.md) | Termux 脚本使用 |
| [docs/operations.md](docs/operations.md) | 状态查询 / 重启 / 升级 / 回滚 / 防火墙 |
| [docs/postmortem.md](docs/postmortem.md) | 故障复盘 |

## 仓库结构

```
ssh-deploy/
├── README.md              ← 你在这里
├── docs/                  ← 全部文档
├── bin/                   ← 离线二进制(OpenSSH zip, frpc.exe)
├── windows/               ← Win PowerShell 脚本
│   ├── ssh-deploy.ps1
│   └── ssh-deploy-poller.ps1
├── linux/                 ← VPS 端组件
│   ├── ssh-deploy-api/server.py
│   ├── nginx-ssh-deploy.conf
│   └── systemd/           ← ssh-deploy-api.service + drop-ins
└── termux/ssh-deploy.sh
```