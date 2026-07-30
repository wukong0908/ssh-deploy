# JSON Schema - ssh-deploy hosts.json

> VPS 上 `/var/lib/ssh-deploy/hosts.json` 的字段约定.
> 客户端拉 JSON 后,逐项生成 `~/.ssh/config` 的 `Host wpc-*` 段.

## 顶层结构

```json
{
  "version": "1.0",
  "servers": [ <server>, <server>, ... ]
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `version` | string | 是 | 当前固定 `"1.0"`(未来扩展用) |
| `servers` | array | 是 | 服务端列表,空数组 = `[]` |

## server 条目

```json
{
  "name": "home",
  "vps_host": "8.163.106.31",
  "ssh_port": 6000,
  "ssh_user": "WuKong",
  "alias": "wpc-home",
  "desc": "Win11 主主机 DESKTOP-WK",
  "owner": "wukong0908",
  "added_at": "2026-07-31T10:00:00Z"
}
```

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `name` | string | 是 | 唯一短名(注册 / 注销用). 例:`home` / `dev` |
| `vps_host` | string | 否* | VPS 地址. *若与主 VPS 不同才需填;空 = 客户端脚本用 `DEFAULT_VPS` 顶替 |
| `ssh_port` | int | 是 | frp 转发的端口(:6000 / :6001 ...),客户端 SSH 连这里 |
| `ssh_user` | string | 是 | **SSH 严格大小写**. 主人机 `WuKong`,老机器 `wukong` |
| `alias` | string | 否 | 默认 `wpc-<name>`. 客户端生成 SSH config 的 `Host` 段名 |
| `desc` | string | 否 | 主机描述,人看,不影响 SSH |
| `owner` | string | 否 | 主人,默认 `wukong0908` |
| `added_at` | string | 否 | ISO 8601 UTC. server 自动填 |

## 客户端生成 SSH config 示例

`name=home` 的条目 → 写到 `~/.ssh/config`:

```sshconfig
# ===== ssh-deploy: home =====
Host wpc-home
    HostName 8.163.106.31
    Port 6000
    User WuKong
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
```

用户输 `ssh wpc-home` + Win 密码 → 进对应主机.

## 字段修改影响

| 改 | 影响 |
|---|---|
| `ssh_port` | 改 frp 转发端口后,客户端拉清单自动用新值 |
| `ssh_user` | 改主机账号名后,客户端 SSH 自动用对大小写 |
| `alias` | 改后,旧 alias 失效;客户端拉清单会用新 alias |
| `desc` / `owner` / `added_at` | 纯展示,不影响 SSH |

## dedup 规则

注册中心按 `name` dedup. 重复注册同名 → 覆盖(`added_at` 更新为最新).
删除只按 `name`,不按 `alias`.

## 安全约束

- ❌ `ssh_user` 不要写成"root" / "Administrator" — 用主人自己的账号
- ❌ 公开 Bearer token 等价于公开 frp 入口 — 只防路人,真正安全靠 VPS 上换 token
- ✅ `name` 短好记即可;`desc` 多写方便自己分机器