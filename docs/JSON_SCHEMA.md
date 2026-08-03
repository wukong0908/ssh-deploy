# JSON Schema - ssh-deploy 数据文件 (v2 / 2026-08-03)

> v2 重塑后,server.py 管两类数据:devices.json(设备清单)+ shared.json(共享 folder).
> 老 hosts.json 不再被 server 读(frp 客户端的中间产物),保留作历史.

## devices.json

路径: `/var/lib/ssh-deploy/devices.json`
权限: 0640,sshdeploy:sshdeploy

```json
{
  "version": "1.0",
  "devices": [
    {
      "device_id": "diag-final",
      "device_name": "diag",
      "owner": "wukong0908",
      "capabilities": {
        "sshd": { "user": "WuKong" }
      },
      "auth_token": "32位hex32位hex32位hex32位hex",
      "registered_at": "2026-08-03T04:35:45Z",
      "last_update": "2026-08-03T04:36:58Z",
      "last_heartbeat": "2026-08-03T12:08:00Z",
      "last_seen": "2026-08-03T12:08:00Z",
      "online": true
    }
  ]
}
```

### 字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `device_id` | string | 是 | 唯一短名,匹配 `[A-Za-z0-9._:-]{1,128}`,**防 path 注入** |
| `device_name` | string | 是 | 显示名,1-128 字符 |
| `owner` | string | 是 | 主人,1-64 字符,默认 `wukong0908` |
| `capabilities` | object | 否 | 设备能力描述,自由结构(常含 `sshd.user` / `syncthing.folders` / `frpc.remote_port`) |
| `auth_token` | string | 是 | 32 字节 hex(secrets.token_hex(16)). register 时生成, heartbeat 必须用 `X-Device-Token` 头验证 |
| `registered_at` | ISO ts | 是 | 首次注册时间 |
| `last_update` | ISO ts | 是 | 任何字段变更的最后时间 |
| `last_heartbeat` | ISO ts | 是 | 上次心跳时间(用于 online 判定,30s 阈值) |
| `last_seen` | ISO ts | 是 | 上次任何活动(deregister 之外) |
| `online` | bool | 是 | 派生字段,checker 线程每 5s 检查,30s 没心跳置 false |

### 迁移

- 旧 devices.json 无 `auth_token` / `last_heartbeat` → server 启动时**自动补**(main → bootstrap → _with_data_lock)
- 已有字段不重置,capabilities 保留

## shared.json

路径: `/var/lib/ssh-deploy/shared.json`
权限: 0640

```json
{
  "version": "1.0",
  "folders": [
    {
      "folder_id": "research-2026",
      "name": "研究生资料",
      "members": [
        {
          "device_id": "diag-final",
          "folder_path": "D:/syncthing/research",
          "joined_at": "2026-08-03T12:00:00Z"
        }
      ],
      "created_at": "2026-08-03T12:00:00Z",
      "updated_at": "2026-08-03T12:00:00Z"
    }
  ]
}
```

### 字段

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `folder_id` | string | 是 | 匹配 `[A-Za-z0-9._:-]+`,最大 128 |
| `name` | string | 是 | 显示名,默认 = folder_id |
| `members` | array | 是 | 加入的设备列表,每条带 `device_id` / `folder_path` / `joined_at` |
| `created_at` | ISO ts | 是 | 创建时间 |
| `updated_at` | ISO ts | 是 | 最后一次 members 变化 |

## hosts.json (历史,本服务不读)

路径: `/var/lib/ssh-deploy/hosts.json`
状态: **保留,不再被 server.py 处理** — 是 frp 客户端最早注册的"ssh 转发主机"清单, 现 frp 客户端用 [ssh] proxy name 直接注册, 不走 server.

如果将来要清理: `rm /var/lib/ssh-deploy/hosts.json` 是安全的(server 不读).

## 端点

| 方法 | 路径 | 鉴权 | 用途 |
|---|---|---|---|
| GET | `/healthz` | 无 | 健康检查(返 V2 字段) |
| GET | `/device/list` | admin 或 device | 列设备(device token 仅看自己) |
| GET | `/device/changes?since=&wait=` | admin 或 device | 长轮询(最长 35s) |
| GET | `/shared/list` | **admin** | 列共享 |
| GET | `/status` | **admin** | 实时状态(可观测性) |
| POST | `/device/register` | **admin** | 注册设备,返 auth_token |
| POST | `/device/heartbeat` | **device** | 心跳,`X-Device-Token` 头 |
| POST | `/device/deregister` | **device** | 注销,清 shared members |
| POST | `/shared/create` | **admin** | 创建共享 |
| POST | `/shared/join` | **admin** | 设备加入共享(自动写 capabilities.syncthing.folders) |
| POST | `/shared/leave` | **admin** | 设备退出共享 |

## 错误码

| code | 含义 |
|---|---|
| 200 | OK |
| 400 | body 校验失败(缺字段 / 类型错 / 长度超 / path 注入 / body 超 8KB) |
| 401 | 鉴权过但权限不够(如 heartbeat 用了 admin token 而非 device token) |
| 403 | 鉴权失败(无 token / 错 token) |
| 404 | 端点不存在 / device 未注册 / folder 未找到 |
| 409 | 冲突(folder_id 已存在) |
| 500 | 文件 IO 失败 / 内部错误 |
| 503 | BEARER_TOKEN 未配置(启动错) |
