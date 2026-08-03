# JSON Schema (v2)

## devices.json

路径: `/var/lib/ssh-deploy/devices.json`
权限: 0640, sshdeploy:sshdeploy

```json
{
  "version": "1.0",
  "devices": [
    {
      "device_id": "ABC-XYZ-123",
      "device_name": "wk-home",
      "owner": "wukong0908",
      "capabilities": {
        "sshd": { "user": "WuKong" },
        "frpc": { "remote_port": 6000 },
        "syncthing": { "folders": ["research-2026"] }
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
| `device_name` | string | 是 | 显示名,1-128 字符。SSH alias = `wpc-<device_name>` |
| `owner` | string | 是 | 主人,1-64 字符,默认 `wukong0908` |
| `capabilities` | object | 否 | 设备能力描述,自由结构(常含 `sshd.user` / `frpc.remote_port` / `syncthing.folders`) |
| `auth_token` | string | 是 | 32 字节 hex(`secrets.token_hex(16)`)。register 时生成,heartbeat 必须用 `X-Device-Token` 头 |
| `registered_at` | ISO ts | 是 | 首次注册时间 |
| `last_update` | ISO ts | 是 | 任何字段变更的最后时间 |
| `last_heartbeat` | ISO ts | 是 | 上次心跳时间(用于 online 判定,30s 阈值) |
| `last_seen` | ISO ts | 是 | 上次任何活动(deregister 除外) |
| `online` | bool | 是 | 派生字段,checker 线程每 5s 检查,30s 没心跳置 false |

### capabilities 校验

`capabilities.syncthing.folders` 必须 `list[str]`(B5 校验)。其它嵌套对象自由结构。

### 迁移

- 旧 devices.json 无 `auth_token` / `last_heartbeat` → server 启动时**自动补**(bootstrap → _with_data_lock)
- 已有字段不重置,capabilities 保留
- register 同 device_id 时**不 rotate** token(保旧 token)

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
          "device_id": "ABC-XYZ-123",
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

device 加入时同步把 `folder_id` 写入 `device.capabilities.syncthing.folders`。

## 历史:hosts.json

`/var/lib/ssh-deploy/hosts.json` 是 frp 客户端最早注册的"ssh 转发主机"清单。
**v2 server.py 不读这个文件**。留着作历史。如要清理:`rm /var/lib/ssh-deploy/hosts.json` 安全。