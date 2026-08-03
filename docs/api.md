# API 参考 (v2)

base: `http://8.163.106.31:8080` (nginx :8080 → :8081 internal)
auth: `Authorization: Bearer <admin>` 或 `X-Device-Token: <per-host>`

## 端点

| 方法 | 路径 | 鉴权 | 用途 |
|---|---|---|---|
| GET | `/healthz` | 无 | 健康检查 (V2 字段) |
| GET | `/device/list` | admin 或 device | 列设备(device token 仅看自己) |
| GET | `/device/changes?since=&wait=` | admin 或 device | 长轮询(最长 35s) |
| GET | `/shared/list` | admin | 列共享 folder |
| GET | `/status` | admin | 实时状态(可观测性) |
| POST | `/device/register` | admin | 注册设备,返 auth_token |
| POST | `/device/heartbeat` | device | 心跳,X-Device-Token 头 |
| POST | `/device/deregister` | device | 注销,清 shared members |
| POST | `/shared/create` | admin | 创建共享 |
| POST | `/shared/join` | admin | 设备加入共享 |
| POST | `/shared/leave` | admin | 设备退出共享 |

## /healthz

```bash
curl http://8.163.106.31:8080/healthz
```

```json
{
  "ok": true,
  "ts": "2026-08-03T13:00:00Z",
  "version": "2.0",
  "uptime_s": 123.4,
  "devices_online": 2,
  "devices_total": 3,
  "last_heartbeat_age_s": 5.2,
  "data_dir_writable": true,
  "token_configured": true
}
```

## /device/list

```bash
curl -H "Authorization: Bearer $TOK" http://8.163.106.31:8080/device/list
```

`{version, devices:[{device_id, device_name, owner, capabilities, auth_token, registered_at, last_update, last_heartbeat, last_seen, online}]}`
device token 鉴权时只看到自己那条。

## /device/changes

```bash
curl -H "Authorization: Bearer $TOK" "http://8.163.106.31:8080/device/changes?since=0&wait=30"
```

长轮询:`since` 是 epoch 秒,`wait` 是秒数(上限 35s)。有变更立即返,否则 hold 到变更或超时。
返 `{changes:[{op, device_id, device_name, capabilities, online, ts}], ts}`。
shared 变更是 `op=shared_update`,带 `folder_id, name, members`。

## /device/register

```bash
curl -X POST -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"abc-123","device_name":"wk-home","capabilities":{"sshd":{"user":"WuKong"},"frpc":{"remote_port":6000},"syncthing":{"folders":[]}}}' \
  http://8.163.106.31:8080/device/register
```

返 200 + `auth_token`(32 hex)。existing device_id 走更新路径,**不 rotate** token。

## /device/heartbeat

```bash
curl -X POST -H "X-Device-Token: $TOK" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"abc-123"}' \
  http://8.163.106.31:8080/device/heartbeat
```

返 200 `{ok, online:true}` / 404 device not registered。

## /device/deregister

同上鉴权头 + `{"device_id":"abc-123"}`,同时从 shared folder 清掉该 device 的 member。

## /shared/create

```bash
curl -X POST -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d '{"folder_id":"research-2026","name":"研究生资料"}' \
  http://8.163.106.31:8080/shared/create
```

## /shared/join

```bash
curl -X POST -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"abc-123","folder_id":"research-2026","folder_path":"D:/syncthing/research"}' \
  http://8.163.106.31:8080/shared/join
```

同步把 folder_id 写入 device.capabilities.syncthing.folders(list)。

## /shared/leave

```bash
curl -X POST -H "Authorization: Bearer $TOK" \
  -H "Content-Type: application/json" \
  -d '{"device_id":"abc-123","folder_id":"research-2026"}' \
  http://8.163.106.31:8080/shared/leave
```

## /status

admin 实时状态,devices 列表含 `age_s` 但**不返 auth_token**。

## 错误码

| code | 含义 |
|---|---|
| 200 | OK |
| 400 | body 校验失败(缺字段 / 类型错 / 长度超 / path 注入 / body 超 8KB) |
| 401 | 鉴权过但权限不够(如 heartbeat 用 admin token 而非 device token) |
| 403 | 鉴权失败(无 token / 错 token) |
| 404 | 端点不存在 / device 未注册 / folder 未找到 |
| 409 | 冲突(folder_id 已存在) |
| 500 | 文件 IO 失败 / 内部错误 |
| 503 | BEARER_TOKEN 未配置(启动错) |