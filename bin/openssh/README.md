# 离线 OpenSSH 包

> 把微软官方 `Win32-OpenSSH` 塞进仓,部署脚本走本地 zip → WinSxS → Windows Update 三级优先级,**不再被 Windows Update CDN 拖到 30 分钟**.

## 包信息

| 项 | 值 |
|---|---|
| 来源 | https://github.com/PowerShell/Win32-OpenSSH/releases/tag/v9.5.0.0p1-Beta |
| 文件 | `OpenSSH-Win64.zip` |
| 大小 | 4.8 MB |
| sha256 | `bd48fe985d400402c278c485db20e6a82bc4c7f7d8e0ef5a81128f523096530c` |
| 许可 | BSD / 公有领域(微软 release) |
| 内容 | `sshd.exe / ssh.exe / ssh-keygen.exe / ssh-agent.exe / sftp-server.exe / scp.exe / ssh-add.exe` 等 29 文件 |

## 装脚本优先级

1. **本仓 zip**(`<script>/bin/openssh/OpenSSH-Win64.zip`,相对脚本目录)
   - `irm ... \| iex` 跑时从 raw.githubusercontent.com 拉脚本,脚本再拉 zip — 全程 HTTP
   - 解压到 `%SystemRoot%\System32\OpenSSH\`(走 `schtasks /RU SYSTEM` + `cmd /c xcopy` 模板,绕 ACL)
2. **本机 WinSxS**(`%SystemRoot%\WinSxS\amd64_openssh-*-components-onecore_*`)
   - Win10 22H2+/Win11 自带,5 秒拷完
3. **Windows Update CDN**(`Add-WindowsCapability`)
   - 兜底,可能 5 ~ 30 分钟

## 重生成 zip

需要换版本时(注意 sha256 必改):

```bash
VERSION=9.5.0.0p1-Beta
curl -fsSLO "https://github.com/PowerShell/Win32-OpenSSH/releases/download/v${VERSION}/OpenSSH-Win64.zip"
certutil -hashfile OpenSSH-Win64.zip SHA256
# 把新 sha256 写到本文档
```

## 不要做的事

- ❌ 不要把 `OpenSSH-Win64/` 解压目录一起塞仓(zip 已经够)
- ❌ 不要把 zip 拆分成 cab(增加复杂度,无收益)
- ❌ 不要从二手镜像下(只从 `github.com/PowerShell/Win32-OpenSSH/releases`)