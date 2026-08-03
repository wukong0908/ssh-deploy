# 故障复盘

## 2026-07-31 坑(初部署 v1)

1. **ufw ≠ 阿里云 SG**:VPS ufw 放行不等于 ECS 安全组放行。`ssh wpc-dev` 第一次超时 21s,
   根因是 ECS SG 没放 :6001。**两层都要放**。
2. **:8080 不通**:首次部署 ECS SG 没放 :8080(只放 22 + 7000 + 6000)。`curl :8080/healthz` 21s 超时。
3. **env 注入 chain 失败**:nginx `env BEARER_TOKEN;` 在 conf.d 报 "directive not allowed here",
   移到 http {} 后 Type=forking service 不传 env 到 worker。**fallback**:token 硬编码进 nginx map。

## 2026-08-03 重塑 + 优化坑(v2)

1. **:8081 公网暴露(S1)**:ssh-deploy-api :8081 ufw ALLOW IN Anywhere,nginx Bearer 鉴权
   **被绕过**。直连 :8081 无鉴权。修复:ufw + 阿里云 SG 双删入方向;只 :8080 nginx 走 Bearer。
2. **register 不 rotate token(B16)**:同 device_id 重 register **不** rotate auth_token。
   device 完全重装若忘 token → 永久卡死,只能重装系统。**待加** `POST /device/rotate-token`(admin)。
3. **/_collect_changes_since op 错(B1)**:`updated_at` 字段 server 从未写,`op` 永远 `register`。
   修:用 `last_update != registered_at` 判 update。
4. **capabilities.syncthing.folders 类型错(B5)**:register 接受 string `folders=""`,leave 时
   `.remove()` 在 string 上抛 AttributeError。修:加 `_validate_caps` 强制 list[str]。
5. **nginx reload 不刷 worker**:本环境 `systemctl reload nginx` 不刷 worker 配置,必须 `stop+start`。
   已在 `deploy-vps.md` 标注。

## 2026-08-03 ssh wpc-home 别名坑

`~/.ssh/config` 没 `Host wpc-home` 块,服务全活但别名不通。主人 ssh -p 6000 直连 OK,
`ssh wpc-home` 报"could not resolve hostname"。修复:加 Host 块,HostName=VPS, Port=6000, User=WuKong。