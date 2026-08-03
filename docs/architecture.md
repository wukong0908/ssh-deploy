# 架构 (2026-08-03 v2)

## 总览

```
                   VPS 8.163.106.31 (Ubuntu 22.04)
                   ┌────────────────────────────────────────┐
                   │ frps :7000 (控制) + :6000/:6001 (转发) │
                   │ nginx :8080 → :8081 (反代 + Bearer)    │
                   │ ssh-deploy-api :8081 (内部,仅本机)     │
                   │ /var/lib/ssh-deploy/{devices,shared}.json│
                   └──────────────┬─────────────────────────┘
                                  │ HTTP
       ┌──────────────────────────┼──────────────────────────┐
       │                          │                          │
   Win 主机 A                 Win 主机 B                 客户端
   DESKTOP-WK                  DESKTOP-DEV                (Win / Termux)
   sshd :22                    sshd :22                   ssh.exe
   frpc → :6000                frpc → :6001               ssh wpc-<name>
   poller (Task Scheduler)     poller                     (无 frpc)
```

## 数据流

### 1. 反向 SSH (主机接入)

```
主机 sshd :22 ──(本机)── frpc ──:7000 控制面──► frps ──:6000 LISTEN
                                                       │
                                                       ▼
                   客户端 ssh wpc-home ──► VPS :6000 ──► 主机 :22 (via frp)
```

### 2. 心跳 (在线判定)

```
主机 poller ──5s/次──► POST /device/heartbeat
                          X-Device-Token: <per-host>
                          {"device_id":"..."}
                                   │
                                   ▼
                  server 改 last_heartbeat + online=true
```

VPS 后台线程 `_heartbeat_checker` 每 5s 检查;30s 没心跳 → `online=false`。

### 3. 长轮询 (变更同步)

```
主机 poller ──► GET /device/changes?since=<ts>&wait=30
                              │
                              ▼
              server 查 changes;若无 → Waiter + Queue 阻塞
                                  │  (waiter.since_ts, 直到 _wake_all 或 35s timeout)
                                  ▼
              任何 register/deregister/shared_create/join/leave
              → _wake_all() → 返 changes
                              │
                              ▼
              poller 收到 → 重拉 /device/list + /shared/list
                          → 改 ~/.ssh/config 段
                          → 改 Syncthing config.xml
                          → Restart-Syncthing
                          → Save-State(last_ts)
```

### 4. 注册流程 (装机)

```
Win 主机 [2] Install  ─► 装 sshd + frpc + 写 frpc.toml + schtasks frpc-bg
                       ─► 拉 VPS device list → 写 ~/.ssh/config
                       ─► Bearer + POST /device/register (admin)
                       ─► 返 auth_token (32 hex) → 存 frpc 配置 / 本机 deploy-secrets.md
                       ─► poller 启动后自动用 X-Device-Token 心跳
```

## 安全边界

| 层 | 控制 |
|---|---|
| Bearer token | nginx map 硬编,改 token 需同步 server env + nginx map + restart 双 |
| Per-host token | `secrets.token_hex(16)` 32 hex,register 时生成,heartbeat 校验 |
| :8081 direct | ufw + 阿里云 SG 都拒绝公网(S1),仅 127.0.0.1 |
| systemd | hardening drop-in: NoNewPrivileges, ProtectSystem=strict, 14 项 |
| sshd | PasswordAuthentication=yes,删 Match Group administrators |
| frp token | frpc.toml + frps.toml 一致 |

## 端口清单

| 端口 | 用途 | 公网? |
|---|---|---|
| :22 | VPS sshd 兜底 | ✅ |
| :7000 | frps 控制面 | ✅ |
| :6000 | frp SSH 转发(主主机) | ✅ |
| :6001 | frp SSH 转发(第二台) | ✅ (0 在线时闲置) |
| :8080 | nginx 反代 ssh-deploy-api | ✅ |
| :8081 | ssh-deploy-api direct | ❌ 仅本机 |
| Win :22 | 本机 sshd(被 frp 转发) | n/a(本机) |