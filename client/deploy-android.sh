#!/data/data/com.termux/files/usr/bin/bash
# deploy-android.sh
# Termux 一键部署 SSH client,使 Android 通过 FRP VPS 连回本机 Win11。
# 不含任何硬编码私钥 / 密码。

set -e

DEFAULT_VPS="8.163.106.31"
DEFAULT_PORT=6000

# ---------- 0. 检查 Termux 环境 ----------
if [ ! -d "/data/data/com.termux" ]; then
    echo "❌ 这个脚本必须在 Termux 里跑,不是普通 Linux/macOS bash。"
    exit 1
fi

# ---------- 1. 装 OpenSSH + git ----------
echo "[1/5] 安装 openssh / git..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y openssh git

# ---------- 2. 准备 ~/.ssh ----------
echo "[2/5] 准备 ~/.ssh"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# ---------- 3. 交互收集配置 ----------
read -rp "VPS 公网 IP 或域名 [${DEFAULT_VPS}]: " VPS_HOST
VPS_HOST=${VPS_HOST:-$DEFAULT_VPS}

read -rp "FRP 转发的 SSH 端口 [${DEFAULT_PORT}]: " SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_PORT}

read -rp "本机 Win11 的 SSH 用户名 (例如 WuKong): " LOCAL_USER

read -rp "私钥文件路径 (例如 ~/.ssh/id_ed25519,放在 Android 上的): " KEY_PATH
KEY_PATH=${KEY_PATH/#\~/$HOME}
if [ ! -f "$KEY_PATH" ]; then
    echo "❌ 私钥文件不存在: $KEY_PATH"
    echo "请先把本机 Win11 的 id_ed25519 通过安全渠道(网盘/局域网 scp/邮件给自己)传到 Android 手机的 $HOME/.ssh/"
    exit 1
fi
chmod 600 "$KEY_PATH"

# ---------- 4. 写 ~/.ssh/config ----------
echo "[4/5] 写入 ~/.ssh/config"
CONFIG="$HOME/.ssh/config"
touch "$CONFIG"
chmod 600 "$CONFIG"

# 避免重复追加
if ! grep -q "Host wukong-pc" "$CONFIG" 2>/dev/null; then
    cat >> "$CONFIG" <<EOF

# ===== ssh-deploy: 通过 FRP 连回本机 Win11 =====
Host wukong-pc
    HostName ${VPS_HOST}
    Port ${SSH_PORT}
    User ${LOCAL_USER}
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
EOF
else
    echo "config 里已有 wukong-pc 段,跳过"
fi

# ---------- 5. 创建便捷 alias ----------
echo "[5/5] 配置 bash alias"
BASHRC="$HOME/.bashrc"
touch "$BASHRC"
if ! grep -q "alias wpc=" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<'EOF'

# ssh-deploy alias
alias wpc='ssh wukong-pc'
EOF
fi

echo ""
echo "============================================"
echo "✅ 部署完成!"
echo "  在 Termux 里输:  ssh wukong-pc"
echo "  或 alias:        wpc"
echo "  首次连会确认 host key,输 yes 后即可登录。"
echo "============================================"