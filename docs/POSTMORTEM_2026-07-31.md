# ssh-deploy 老机器 dev 端到端联调复盘 — 2026-07-31

> 一次性踩坑清单,防止后人(和未来的我)重蹈覆辙。

## 目标

主机 `ssh wpc-dev` 经 VPS frps 中转连老机器(账号 `wukong`,端口 6001)。

## 8 坑按时间顺序

| # | 现象 | 根因 | 修法 | Commit |
|---|------|------|------|--------|
| 1 | `irm ... \| iex` 流式报 "irm 不认识 -VpsHost" | 多行 PS + 反引号 iex 解析时 `-VpsHost` 被当 irm 参数 | 下到文件再 `& $ps -Param ...` | — |
| 2 | `Get-WindowsCapability ... 没有注册类` halt | `$ErrorActionPreference=Stop` + Appx 缺失 → terminating,fallback 全废 | 探针 try/catch | `7906f3b` |
| 3 | `ExtractToDirectory` 报"包含病毒或潜在的垃圾软件" | Defender 实时扫描拦所有解压 API | bundle frpc.exe 进 `bin/`(治本) | `b46a7f1` |
| 4 | `Get-Content $logPath` 报"文件不存在" | `schtasks /RU SYSTEM` 在老机器禁 SeBatchLogonRight,bat 永不触发 | `Start-Process cmd.exe -Wait`(已是管理员) | `22f4440` |
| 5 | `frpc.exe not found ..\bin\frp\` | `$PSScriptRoot` 在 `& $ps` 调用下 = `$env:TEMP`,`..\` 解析错 | `irm` raw URL 拉 bundled 二进制 | `6a8dcc5` |
| 6 | `ssh wpc-dev` 后 `port 6001` `Connection timed out` | VPS ufw + ECS 安全组两层只配了 ufw;frpc `[ssh]` proxy name 撞主人机 | proxy name = `$ServerName`;ufw + ECS 都加 6001 | `557cea6` |
| 7 | 主机 client install 报 "Bearer Unexpected token" | PS 5.1 无 BOM 的 .ps1 用 ANSI (936 GBK) 解 UTF-8 中文 → 乱码 | 加 UTF-8 BOM (EF BB BF) + `.gitattributes` | `279ea35` |
| 8 | frpc 在 frps 报 `proxy [ssh] already exists` | 老机器 ini `[ssh]` 与主人机 `[ssh]` 撞 frps;另 `C:\frp\` 残留 stale frpc | 改 proxy name = `$ServerName`;删 `C:\frp\` | `557cea6` / cleanup.bat |

## 5 条核心教训(跨项目复用)

1. **PS 5.1 + 中文 .ps1**:必须 UTF-8 BOM;无 BOM → ANSI codepage 解 → 中文 / emoji / here-strings 全乱
2. **Defender AMSI + 网络下载 zip**:Unblock-File / ZipArchive enumerate / Add-MpPreference 都可能不够;**根治 = bundle 解压后二进制进仓**
3. **schtasks /RU SYSTEM**:LTSC / 老机器常禁 SeBatchLogonRight,bat 永不触发;**当前是管理员就直接 `Start-Process -Wait`**
4. **frp proxy name**:多主机同 frps 时,**proxy name 必须唯一**(用 `$ServerName` 而非硬编码 `ssh`)
5. **VPS 两层防火墙**:ufw + 阿里云 ECS 安全组,**两层都要放**,单层不够

## 当前状态(2026-07-31 23:10Z)

- VPS frps 0.61.1 跑 :7000 + :6000(host) + :6001(dev)
- ufw + 阿里云 ECS 安全组都允许 22/7000/6000/6001/8080
- hosts.json: `home` + `dev`(server.py dedup by vps_host+port+user)
- 老机器:frpc schtask `[dev] @ :6001`,用户 `wukong` 设密码
- 主机:`~/.ssh/config` 有 `wpc-home` + `wpc-dev`,profile alias `ssh-home` / `wpc-home` / `ssh-dev` / `wpc-dev`
- `ssh wpc-dev` 通

## 下一步

- D3: Termux 装客户端验证外机通
- D4: 主人机设密码 `net user WuKong *` 让 SSH 密码登录通
- 安全:Bearer token / FRPS token 轮换(本对话历史暴露,改新值)
