# FRP 服务端 / 客户端配置

## 你的 VPS 上(FRPS)

VPS `8.163.106.31` 跑 frps,开放:
- `7000` — frp 控制端口(frpc 连这个)
- `6000` — SSH 流量转发端口(外机连这个)

`frps.ini` 典型配置:

```ini
[common]
bind_port = 7000
vhost_http_port = 80
# token 用于 frpc 连接认证,自定义强密码
token = your_strong_token_here

# 如果要让 frpc 在 vps 上不需要 root 也能跑
privilege_mode = false
```

启动:`nohup ./frps -c frps.ini &`

## 本机(frpc)

下载对应 Windows 版 frpc(从 https://github.com/fatedier/frp/releases),放到
`C:\Tools\frp\frpc.exe`。

`frpc.ini`:

```ini
[common]
server_addr = 8.163.106.31
server_port = 7000
token = your_strong_token_here

[ssh]
type = tcp
local_ip = 127.0.0.1
local_port = 22
remote_port = 6000
```

注册为 Windows 服务自启:

```powershell
# 在 frpc.exe 同目录
.\frpc.exe -c frpc.ini install
.\frpc.exe -c frpc.ini start
```

`scripts/setup-frpc.ps1` 一键完成。

## 验证

外机:`ssh -p 6000 -i ~/.ssh/id_ed25519 wukong@8.163.106.31` → 应进本机 shell。

或者仓库脚本部署完:`ssh wukong-pc`。