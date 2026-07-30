# VPS 部署指南

> 一台 VPS 上同时跑 frps + ssh-deploy-api + nginx 反代.
> 假设 VPS 是 Debian/Ubuntu 系,root 跑.

## 前置

| 项 | 值 |
|---|---|
| VPS 公网 IP | `8.163.106.31` |
| VPS 上 frps | 已跑(:7000),token = `<FRPS_TOKEN>` |
| 主主机 sshd | 在 :22,通过 frp 转 :6000(:6001 = 第二台主机) |
| Bearer token | 主人自定(防路人). 例:`wukong_ssh_2026_secret_xxx` |

## 1. 准备 sshdeploy 用户 + 目录

```bash
useradd -r -s /usr/sbin/nologin sshdeploy
mkdir -p /opt/ssh-deploy /var/lib/ssh-deploy /etc/ssh-deploy
chown -R sshdeploy:sshdeploy /opt/ssh-deploy /var/lib/ssh-deploy
chmod 750 /etc/ssh-deploy /var/lib/ssh-deploy
```

## 2. 上传 server.py

```bash
# 从本仓拷(server.py 已在本目录)
scp vps/ssh-deploy-api/server.py root@8.163.106.31:/opt/ssh-deploy/server.py
ssh root@8.163.106.31 'chown sshdeploy:sshdeploy /opt/ssh-deploy/server.py && chmod 755 /opt/ssh-deploy/server.py'
```

## 3. 写 Bearer token(env 文件)

```bash
ssh root@8.163.106.31
cat > /etc/ssh-deploy/ssh-deploy.env <<EOF
BEARER_TOKEN=wukong_ssh_2026_secret_xxx
API_PORT=8081
SSH_DEPLOY_DATA_DIR=/var/lib/ssh-deploy
EOF
chmod 600 /etc/ssh-deploy/ssh-deploy.env
```

**主人替换 `wukong_ssh_2026_secret_xxx` 为自己的 token**,然后在客户端脚本里同步用同一 token.

## 4. 装 systemd unit

```bash
scp vps/ssh-deploy-api.service root@8.163.106.31:/etc/systemd/system/ssh-deploy-api.service
ssh root@8.163.106.31 '
  systemctl daemon-reload
  systemctl enable --now ssh-deploy-api
  systemctl status ssh-deploy-api
'
```

应看到 `active (running)`.

## 5. 配 nginx

```bash
scp vps/nginx-ssh-deploy.conf root@8.163.106.31:/etc/nginx/conf.d/ssh-deploy.conf
ssh root@8.163.106.31 '
  # 把 nginx conf 里的 "YOUR_TOKEN_HERE" 替成步骤 3 的 token
  sed -i "s/YOUR_TOKEN_HERE/wukong_ssh_2026_secret_xxx/" /etc/nginx/conf.d/ssh-deploy.conf
  nginx -t
  systemctl reload nginx
'
```

## 6. 防火墙放 8080

```bash
ssh root@8.163.106.31 '
  ufw allow 8080/tcp   # 或 iptables -A INPUT -p tcp --dport 8080 -j ACCEPT
'
```

## 7. 自检

```bash
# 健康(免 token)
curl -s http://8.163.106.31:8080/healthz
# {"ok": true, "ts": "..."}

# 鉴权失败
curl -s -o /dev/null -w "%{http_code}\n" http://8.163.106.31:8080/ssh-deploy/hosts
# 应回 403

# 鉴权通过
TOKEN=wukong_ssh_2026_secret_xxx
curl -s -H "Authorization: Bearer $TOKEN" http://8.163.106.31:8080/ssh-deploy/hosts
# {"version": "1.0", "servers": []}

# 注册一台
curl -s -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -X POST http://8.163.106.31:8080/ssh-deploy/register \
  -d '{"name":"home","vps_host":"8.163.106.31","ssh_port":6000,"ssh_user":"WuKong","desc":"DESKTOP-WK"}'
```

## 8. hosts.json 备份(cron)

```bash
ssh root@8.163.106.31 '
  cat > /etc/cron.daily/ssh-deploy-backup <<EOF
#!/bin/bash
cp /var/lib/ssh-deploy/hosts.json /var/lib/ssh-deploy/hosts.json.bak.\$(date +%Y%m%d)
ls -1 /var/lib/ssh-deploy/hosts.json.bak.* | tail -n +8 | xargs -r rm
EOF
  chmod 755 /etc/cron.daily/ssh-deploy-backup
'
```

## 故障排查

| 症状 | 看哪 |
|---|---|
| 502 Bad Gateway | `systemctl status ssh-deploy-api` / `journalctl -u ssh-deploy-api -n 50` |
| 403 但 token 正确 | `nginx -T | grep ssh_deploy_auth_ok` 看 map 块 |
| 数据丢了 | `/var/lib/ssh-deploy/hosts.json.bak.YYYYMMDD` |
| Bearer token 泄露 | `ssh root@8.163.106.31 'sed -i ... /etc/ssh-deploy/ssh-deploy.env && systemctl restart ssh-deploy-api'` |