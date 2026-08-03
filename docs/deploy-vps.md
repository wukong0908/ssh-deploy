# VPS 部署 (v2)

Ubuntu 22.04,root 用户。本指南假设全新部署;升级直接看"升级 / 回滚"段。

## 前置

| 项 | 值 |
|---|---|
| VPS 公网 IP | `8.163.106.31` |
| VPS 上 frps | 已跑(:7000),token 在 `/etc/frp/frps.toml` |
| 主主机 sshd | 在 :22,通过 frp 转 :6000(:6001 = 第二台主机) |
| Bearer token | `/etc/ssh-deploy/ssh-deploy.env` 里 `BEARER_TOKEN=...` |
| sshdeploy 用户 | 系统用户,`/usr/sbin/nologin`,数据 dir 拥有者 |

## 1. sshdeploy 用户 + 目录

```bash
useradd -r -s /usr/sbin/nologin sshdeploy
mkdir -p /opt/ssh-deploy/linux/ssh-deploy-api \
         /opt/ssh-deploy/linux/systemd/ssh-deploy-api.service.d \
         /var/lib/ssh-deploy /etc/ssh-deploy
chown -R sshdeploy:sshdeploy /opt/ssh-deploy /var/lib/ssh-deploy
chmod 750 /etc/ssh-deploy /var/lib/ssh-deploy
chmod 640 /etc/ssh-deploy/ssh-deploy.env
```

## 2. Bearer token 生成

```bash
python3 -c "import secrets; print(secrets.token_urlsafe(32))"
# 写进 env file
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
scp linux/ssh-deploy-api/server.py root@8.163.106.31:/opt/ssh-deploy/linux/ssh-deploy-api/server.py
ssh root@8.163.106.31 'chown sshdeploy:sshdeploy /opt/ssh-deploy/linux/ssh-deploy-api/server.py && chmod 644 /opt/ssh-deploy/linux/ssh-deploy-api/server.py'
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
ExecStart=/usr/bin/python3 /opt/ssh-deploy/linux/ssh-deploy-api/server.py
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
```

Drop-in `/etc/systemd/system/ssh-deploy-api.service.d/hardening.conf`:

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

可选 env backup drop-in `/etc/systemd/system/ssh-deploy-api.service.d/ssh-deploy-env.conf`
(防 EnvironmentFile 路径变更时服务仍能启动,内容可与主 env 一致)。

```bash
systemctl daemon-reload
systemctl enable ssh-deploy-api
systemctl start ssh-deploy-api
```

## 5. nginx 反代

`/etc/nginx/conf.d/ssh-deploy.conf`(从本仓 `linux/nginx-ssh-deploy.conf` 拷,把
`YOUR_TOKEN_HERE` 换成 `/etc/ssh-deploy/ssh-deploy.env` 里的实际 token):

```bash
python3 - <<'PYEOF'
import os
env = {}
with open('/etc/ssh-deploy/ssh-deploy.env') as f:
    for line in f:
        if '=' in line and not line.startswith('#'):
            k, v = line.strip().split('=', 1)
            env[k] = v
p = '/etc/nginx/conf.d/ssh-deploy.conf'
with open(p) as f: s = f.read()
s = s.replace('"Bearer YOUR_TOKEN_HERE"', f'"Bearer {env["BEARER_TOKEN"]}"')
with open(p, 'w') as f: f.write(s)
PYEOF

nginx -t
# 注:本环境 reload 不刷 worker 配置,必须 stop+start
systemctl stop nginx && systemctl start nginx
```

`nginx.conf` 加 `server { listen 8080; ... access_log off; ... }`(server 级 access_log off,
避免 /healthz 高频写 access_log)。

## 6. 防火墙 (双层)

VPS ufw + 阿里云 ECS 安全组都放:

| 端口 | 用途 |
|---|---|
| 22/tcp | SSH 兜底 |
| 7000/tcp | frp 控制 |
| 6000/tcp / 6001/tcp | frp 转发 |
| 8080/tcp | ssh-deploy-api(nginx, **唯一公网入口**) |
| 8081/tcp | ssh-deploy-api direct, **仅本机**,ufw + SG 拒绝入(防绕过 nginx Bearer) |

```bash
# VPS ufw
ufw allow 22/tcp
ufw allow 7000/tcp
ufw allow 6000/tcp
ufw allow 6001/tcp
ufw allow 8080/tcp
# 8081 不加(默认拒绝入)

# 阿里云 SG
aliyun ecs AuthorizeSecurityGroup --SecurityGroupId <sg-id> --region cn-guangzhou \
  --IpProtocol tcp --PortRange 22/22 --SourceCidrIp 0.0.0.0/0
# ... 同样对 7000, 6000, 6001, 8080
# 8081 不加
```

## 7. 验证

```bash
TOKEN=$(grep '^BEARER_TOKEN=' /etc/ssh-deploy/ssh-deploy.env | cut -d= -f2-)
curl -s http://127.0.0.1:8080/healthz | python3 -m json.tool
# 期望: {"ok": true, "version": "2.0", "devices_online": N, ...}

curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/device/list | python3 -m json.tool
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/status | python3 -m json.tool

# 安全分(预期 ≤ 1.7)
systemd-analyze security ssh-deploy-api 2>&1 | tail -1

# 公网 :8081 应连不上(防绕过)
curl -m 3 http://8.163.106.31:8081/healthz   # expect connection refused
```

## 8. 升级 / 回滚

升级:
```bash
cd /opt/ssh-deploy
git pull
systemctl restart ssh-deploy-api
# 若 nginx conf 改: nginx -t && systemctl stop nginx && systemctl start nginx
```

回滚 server.py:
```bash
cp /opt/ssh-deploy/linux/ssh-deploy-api/server.py.v1.bak.<ts> \
   /opt/ssh-deploy/linux/ssh-deploy-api/server.py
systemctl restart ssh-deploy-api
```

## 9. 改 Bearer token

1. 改 `/etc/ssh-deploy/ssh-deploy.env` 里的 `BEARER_TOKEN=`
2. 重跑第 5 步的 Python 替换 nginx map 里的 token
3. `systemctl restart ssh-deploy-api`
4. `systemctl stop nginx && systemctl start nginx`(本环境必须 stop+start)
5. 客户端 token cache (`~/.ssh/deploy-secrets.md`) 同步更新