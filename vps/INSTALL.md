# VPS 部署指南 (v2 / 2026-08-03)

> 一台 VPS 上同时跑 frps + ssh-deploy-api + nginx 反代.
> 假设 VPS 是 Debian/Ubuntu 系,root 跑.

## 前置

| 项 | 值 |
|---|---|
| VPS 公网 IP | `8.163.106.31` |
| VPS 上 frps | 已跑(:7000),token 在 `/etc/frp/frps.toml` |
| 主主机 sshd | 在 :22,通过 frp 转 :6000(:6001 = 第二台主机) |
| Bearer token | `/etc/ssh-deploy/ssh-deploy.env` 里 `BEARER_TOKEN=...` |
| sshdeploy 用户 | 系统用户,`/usr/sbin/nologin`,数据 dir 拥有者 |

## 1. 准备 sshdeploy 用户 + 目录

```bash
useradd -r -s /usr/sbin/nologin sshdeploy
mkdir -p /opt/ssh-deploy/vps/ssh-deploy-api /var/lib/ssh-deploy /etc/ssh-deploy
chown -R sshdeploy:sshdeploy /opt/ssh-deploy /var/lib/ssh-deploy
chmod 750 /etc/ssh-deploy /var/lib/ssh-deploy
chmod 640 /etc/ssh-deploy/ssh-deploy.env
```

## 2. 生成 Bearer token

```bash
# 32+ 字节随机
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
# 写到 env file
cat > /etc/ssh-deploy/ssh-deploy.env <<EOF
BEARER_TOKEN=<粘贴上面那串>
API_PORT=8081
SSH_DEPLOY_DATA_DIR=/var/lib/ssh-deploy
EOF
chown sshdeploy:sshdeploy /etc/ssh-deploy/ssh-deploy.env
chmod 640 /etc/ssh-deploy/ssh-deploy.env
```

## 3. 部署 server.py

```bash
# 从本仓拷
scp vps/ssh-deploy-api/server.py root@8.163.106.31:/opt/ssh-deploy/vps/ssh-deploy-api/server.py
ssh root@8.163.106.31 'chown sshdeploy:sshdeploy /opt/ssh-deploy/vps/ssh-deploy-api/server.py && chmod 644 /opt/ssh-deploy/vps/ssh-deploy-api/server.py'
```

## 4. systemd service

`/etc/systemd/system/ssh-deploy-api.service`:

```ini
[Unit]
Description=ssh-deploy API (device directory + long-polling)
After=network.target

[Service]
Type=simple
User=sshdeploy
Group=sshdeploy
EnvironmentFile=/etc/ssh-deploy/ssh-deploy.env
ExecStart=/usr/bin/python3 /opt/ssh-deploy/vps/ssh-deploy-api/server.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/ssh-deploy-api.service.d/hardening.conf` (drop-in):

```ini
[Service]
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/lib/ssh-deploy
PrivateTmp=yes
RestrictSUIDSGID=yes
RestrictNamespaces=yes
RestrictRealtime=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
LockPersonality=yes
MemoryDenyWriteExecute=yes
ProtectKernelTunables=yes
ProtectKernelModules=yes
ProtectControlGroups=yes
ProtectHostname=yes
ProtectClock=yes
ProtectProc=invisible
ProcSubset=pid
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
SystemCallErrorNumber=EPERM
CapabilityBoundingSet=
AmbientCapabilities=
```

```bash
systemctl daemon-reload
systemctl enable ssh-deploy-api
systemctl start ssh-deploy-api
```

**可选 drop-in**(环境变量备份):
`/etc/systemd/system/ssh-deploy-api.service.d/ssh-deploy-env.conf` — 内容可与 `/etc/ssh-deploy/ssh-deploy.env` 一致. 主环境变量已由 `EnvironmentFile=` 提供,本 drop-in 仅防 env 文件路径变更时服务仍能启动.

## 5. nginx 反代

`/etc/nginx/conf.d/ssh-deploy.conf` — 从本仓 `vps/nginx-ssh-deploy.conf` 拷,把 `YOUR_TOKEN_HERE` 换成 `/etc/ssh-deploy/ssh-deploy.env` 里的实际 token.

```bash
# 从 env file 读 token,塞进 map
python3 - <<'PYEOF'
import re
env = dict(line.strip().split('=', 1) for line in open('/etc/ssh-deploy/ssh-deploy.env') if '=' in line and not line.startswith('#'))
p = '/etc/nginx/conf.d/ssh-deploy.conf'
s = open(p).read()
s = s.replace('"Bearer YOUR_TOKEN_HERE"', f'"Bearer {env["BEARER_TOKEN"]}"')
open(p, 'w').write(s)
PYEOF

nginx -t
# 注: 本环境 reload 不刷 worker 配置,必须 stop+start
systemctl stop nginx && systemctl start nginx
```

## 6. 防火墙

VPS 上两层都要放(ufw + 云安全组):

| 端口 | 用途 |
|---|---|
| 22/tcp | SSH 兜底 |
| 7000/tcp | frp 控制 |
| 6000/tcp / 6001/tcp | frp 转发 |
| 8080/tcp | ssh-deploy-api(nginx, **唯一公网入口**) |
| 8081/tcp | ssh-deploy-api direct, **仅本机 127.0.0.1**, ufw/ECS SG 不放(防绕过 nginx Bearer) |

## 7. 端到端验证

```bash
TOKEN=$(grep '^BEARER_TOKEN=' /etc/ssh-deploy/ssh-deploy.env | cut -d= -f2-)
curl -s http://127.0.0.1:8080/healthz | python3 -m json.tool
# 期望: {"ok": true, "version": "2.0", "devices_online": N, ...}

curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/device/list | python3 -m json.tool

curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/status | python3 -m json.tool
```

## 8. 升级 / 回滚

- 升级: 重复步骤 3-5 即可(数据 dir 不动)
- 回滚: `cp /opt/ssh-deploy/vps/ssh-deploy-api/server.py.v1.bak.* /opt/ssh-deploy/vps/ssh-deploy-api/server.py` + `systemctl restart ssh-deploy-api`

## 9. 改 Bearer token

- 改 `/etc/ssh-deploy/ssh-deploy.env` 里的 `BEARER_TOKEN=`
- 重跑第 5 步的 `python3` 替换 nginx map 里的 token
- `systemctl restart ssh-deploy-api`
- `systemctl restart nginx` (本环境必须 stop+start)
