# 网络架构

```
┌─────────────────┐
│  外机 (Win/And) │
│  ssh client     │
└────────┬────────┘
         │  SSH over TCP
         │  公网连接 VPS:6000
         ▼
┌─────────────────────────────────────┐
│  VPS (8.163.106.31)                 │
│  ┌─────────────────────────────┐    │
│  │ frps (frp server)           │    │
│  │  bind_port=7000 (控制)      │    │
│  │  remote_port=6000 (SSH转发) │    │
│  └─────────────┬───────────────┘    │
└────────────────┼────────────────────┘
                 │  内网 TCP 隧道
                 ▼
┌─────────────────────────────────────┐
│  本机 Win11 (DESKTOP-WK)           │
│  ┌─────────────────────────────┐    │
│  │ frpc (frp client)           │    │
│  │  server_addr=8.163.106.31   │    │
│  │  local_port=22              │    │
│  └─────────────┬───────────────┘    │
│                ▼                    │
│  ┌─────────────────────────────┐    │
│  │ OpenSSH sshd (127.0.0.1:22) │    │
│  │  Match Group administrators │ ◄── 已被注释,走 ~/.ssh/authorized_keys
│  │  PasswordAuthentication no  │     密钥认证
│  │  PubkeyAuthentication yes   │     ✓
│  └─────────────────────────────┘    │
└─────────────────────────────────────┘
```

## 流量路径

1. 外机 `ssh -p 6000 WuKong@8.163.106.31`
2. VPS frps 收到连 6000 端口的请求 → 查内部映射表(`[ssh] 段`)
3. frps 通过 7000 控制通道已建立的 frpc 隧道 → 把流量转发到本机 frpc
4. 本机 frpc 收到 → 投到 `127.0.0.1:22` → sshd 处理
5. sshd 验 authorized_keys → 通过 → 进 shell

## 关键点

- **VPS 不需要 SSH 服务**,只跑 frps(纯 TCP 转发)
- **VPS 不持有任何密钥**,密钥只在本机和外机
- **VPS 密码泄露不影响 SSH 安全**(frp token 才影响)
- **frp token 必须强**(参考 FRP_SETUP.md)

## 故障排查

| 现象 | 排查 |
|---|---|
| 外机连 VPS:6000 Connection refused | VPS 防火墙 / frps 没起 / remote_port 不一致 |
| 连接被立即断开 | frp token 不一致,frpc 与 frps 没连上 |
| 连上但 Permission denied | 本机 authorized_keys 没对应公钥 / sshd 配置拒 |
| 连接慢/卡 | VPS 带宽不足 / frpc 本地 22 端口被改 |