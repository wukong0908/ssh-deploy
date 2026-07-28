#!/data/data/com.termux/files/usr/bin/bash
# deploy-android.sh
# Termux 一键部署 SSH client,使 Android 通过 FRP VPS 连回本机 Win11(密码认证)。

set -e

DEFAULT_VPS="8.163.106.31"
DEFAULT_PORT=6000

# ---------- 0. Termux 检查 ----------
if [ ! -d "/data/data/com.termux" ]; then
    echo "❌ 这个脚本必须在 Termux 里跑。"
    exit 1
fi

# ---------- 1. 装 openssh / git ----------
echo "[1/4] 安装 openssh / git..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y openssh git

# ---------- 2. 准备 ~/.ssh ----------
echo "[2/4] 准备 ~/.ssh"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# ---------- 3. 交互收集 ----------
read -rp "VPS 公网 IP 或域名 [${DEFAULT_VPS}]: " VPS_HOST
VPS_HOST=${VPS_HOST:-$DEFAULT_VPS}

read -rp "FRP 转发的 SSH 端口 [${DEFAULT_PORT}]: " SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_PORT}

read -rp "本机 Win11 的账号用户名 (例如 WuKong): " LOCAL_USER

# ---------- 4. 写 ssh config + alias ----------
echo "[3/4] 写 ~/.ssh/config"
CONFIG="$HOME/.ssh/config"
touch "$CONFIG"
chmod 600 "$CONFIG"

if ! grep -q "Host wukong-pc" "$CONFIG" 2>/dev/null; then
    cat >> "$CONFIG" <<EOF

# ===== ssh-deploy: 通过 FRP 连回本机 Win11 =====
Host wukong-pc
    HostName ${VPS_HOST}
    Port ${SSH_PORT}
    User ${LOCAL_USER}
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
EOF
else
    echo "config 里已有 wukong-pc 段,跳过"
fi

echo "[4/4] 配置 bash alias"
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
echo "  Termux 里输:  ssh wukong-pc"
echo "  或 alias:     wpc"
echo "  首次会确认 host key (输 yes)"
echo "  然后提示输 Win11 账号密码(每次连都要输)"
echo "============================================"