# 运维 SOP

## 状态查询

### 一键验证(VPS)

```bash
ssh root@8.163.106.31 'echo "=== services ==="; for s in sshd nginx frps ssh-deploy-api; do printf "%-15s %s\n" "$s" "$(systemctl is-active $s 2>&1)"; done; echo "=== ports ==="; ss -tlnp 2>/dev/null | grep -E ":(22|7000|6000|6001|8080|8081) "; echo "=== healthz ==="; curl -s http://127.0.0.1:8080/healthz; echo; echo "=== security ==="; systemd-analyze security ssh-deploy-api 2>&1 | tail -1'
```

期望:
- 4 active
- 端口 LISTEN(8080 nginx / 8081 ssh-deploy-api / 22 sshd / 7000+6000+6001 frps)
- `/healthz` 返 `version: "2.0"`
- security ≤ 2.0

### API 状态

```bash
TOKEN=$(grep '^BEARER_TOKEN=' /etc/ssh-deploy/ssh-deploy.env | cut -d= -f2-)
curl -s -H "Authorization: Bearer $TOKEN" http://8.163.106.31:8080/status | python3 -m json.tool
```

## 重启

```bash
# ssh-deploy-api
systemctl restart ssh-deploy-api

# nginx(注意:本环境 reload 不刷 worker,必须 stop+start)
systemctl stop nginx && systemctl start nginx

# frps(谨慎,会断所有转发)
systemctl restart frps
```

## 升级

```bash
cd /opt/ssh-deploy
git pull
# server.py 改
systemctl restart ssh-deploy-api
# nginx conf 改
nginx -t && systemctl stop nginx && systemctl start nginx
```

Win 端:`Invoke-WebRequest` 拉新 `windows/ssh-deploy.ps1` 覆盖即可。

## 回滚

```bash
# server.py 回滚(需有 .v1.bak 文件)
cp /opt/ssh-deploy/linux/ssh-deploy-api/server.py.v1.bak.<ts> \
   /opt/ssh-deploy/linux/ssh-deploy-api/server.py
systemctl restart ssh-deploy-api
```

仓历史回滚:
```bash
cd /opt/ssh-deploy
git log --oneline -5
git checkout <hash> -- linux/ssh-deploy-api/server.py
systemctl restart ssh-deploy-api
```

## 改 Bearer token

详见 `deploy-vps.md` 第 9 段。要点:
1. env 文件改
2. nginx map 同步改(本环境无法 env 注入,硬编码)
3. `restart ssh-deploy-api` + `stop+start nginx`
4. 客户端 `~/.ssh/deploy-secrets.md` 同步更新

## 清设备目录

```bash
# 备份
cp /var/lib/ssh-deploy/devices.json /var/lib/ssh-deploy/devices.json.bak.before-clear.<ts>

# 清空(危险,需主人确认)
python3 -c 'import json; d={"version":"1.0","devices":[]}; open("/var/lib/ssh-deploy/devices.json","w").write(json.dumps(d, indent=2))'
chown sshdeploy:sshdeploy /var/lib/ssh-deploy/devices.json
chmod 640 /var/lib/ssh-deploy/devices.json

# 验证
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8080/status | python3 -m json.tool
# devices_total: 0
```

## 防火墙 SOP

每加一台 frp SSH 转发主机,**两层都放**:

```bash
# VPS ufw
ufw allow <port>/tcp

# 阿里云 SG
aliyun ecs AuthorizeSecurityGroup --SecurityGroupId <sg-id> --region cn-guangzhou \
  --IpProtocol tcp --PortRange <port>/<port> --SourceCidrIp 0.0.0.0/0
```

只放一层不够。ufw 看不到 ECS 安全组 DROP,反之亦然。

## 故障排查

| 现象 | 排查 |
|---|---|
| `ssh wpc-home` Connection refused | VPS `ss -tlnp \| grep 6000` 有无 LISTEN;frpc 日志 `C:\frp\frpc.out.log` 有无 login success;aliyun SG 有无放 :6000 |
| `curl :8080/healthz` 超时 | nginx active?`ss -tlnp \| grep 8080`?阿里云 SG 放 :8080? |
| `curl :8080/device/list` 403 | Bearer token 对吗?`grep BEARER_TOKEN /etc/ssh-deploy/ssh-deploy.env` + nginx map token 一致? |
| heartbeat 失败 | `journalctl -u ssh-deploy-api -n 50` 看 401/403/404;X-Device-Token 对吗? |
| frpc 频繁断连 | `C:\frp\frpc.out.log` 看;transport.heartbeatInterval=10,heartbeatTimeout=30 |