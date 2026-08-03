# Termux 部署

主脚本 `termux/ssh-deploy.sh`,**只客户端**。Termux 没有 sshd,只 ssh 出。

## 下载

```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/termux/ssh-deploy.sh | bash -s -- -v 8.163.106.31 -t YOUR_TOKEN
```

或传 commit pin:
```bash
curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/termux/ssh-deploy.sh | bash -s -- -v 8.163.106.31 -t YOUR_TOKEN
```

## 主菜单

```
========== ssh-deploy (Android) =========
  [1] Install (client only)
  [2] Status
  [3] Switch (重拉 VPS 清单)
  [0] Exit
=========================================
```

## Install 流程

1. `pkg install -y openssh`(ssh.exe)
2. 拉 VPS `/device/list`(Bearer) → 解析 `device_name/capabilities.frpc.remote_port/capabilities.sshd.user`
3. 写 `~/.ssh/config` 多 `Host wpc-<device_name>` 段
4. 写 `~/.bashrc` alias(`wpc-<name>` = `ssh wpc-<name>`)

JSON 解析用 `python3` 内置(termux 自带),不依赖 `jq`。

## 验证

```bash
ssh wpc-home   # 进主人机
ssh wpc-dev    # 进第二台主机(若有)
```