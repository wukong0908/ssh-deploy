#!/data/data/com.termux/files/usr/bin/bash
# deploy-android.sh
# Termux 一键部署 SSH client,使 Android 通过 FRP VPS 连回本机 Win11(密码认证)。

# 不 set -e:read 在非交互 stdin(curl|bash)下会失败,导致变量未初始化

DEFAULT_VPS="8.163.106.31"
DEFAULT_PORT=6000
DEFAULT_USER="WuKong"

step() {
    echo ""
    echo "[$1/3] $2"
}

# ---------- 0. Termux 检查 ----------
if [ ! -d "/data/data/com.termux" ]; then
    echo "❌ 这个脚本必须在 Termux 里跑。"
    exit 1
fi

# ---------- 1. OpenSSH Client ----------
step "1/3" "检查 openssh / git..."
if ! command -v ssh >/dev/null 2>&1; then
    echo "正在安装 openssh..."
    pkg update -y >/dev/null 2>&1 || true
    pkg install -y openssh git
else
    echo "openssh 已安装。"
fi
if ! command -v ssh >/dev/null 2>&1; then
    echo "❌ 安装后仍找不到 ssh。重启 Termux 再试。"
    exit 1
fi

SSH_DIR="$HOME/.ssh"
mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

# ---------- 2. 收集参数 ----------
step "2/3" "收集连接参数"
if [ -t 0 ]; then
    printf "VPS 公网 IP 或域名 [%s]: " "$DEFAULT_VPS"; read -r VPS_HOST
    printf "FRP 转发的 SSH 端口 [%s]: " "$DEFAULT_PORT"; read -r SSH_PORT
    printf "本机 Win11 的账号用户名 (例如 %s): " "$DEFAULT_USER"; read -r LOCAL_USER
fi
VPS_HOST=${VPS_HOST:-$DEFAULT_VPS}
SSH_PORT=${SSH_PORT:-$DEFAULT_PORT}
LOCAL_USER=${LOCAL_USER:-$DEFAULT_USER}
if [ -z "$LOCAL_USER" ]; then
    echo "❌ 用户名不能为空,脚本退出"
    exit 1
fi

# ---------- 3. 写 config + alias ----------
step "3/3" "写入 ~/.ssh/config 和 bash alias"
CONFIG="$SSH_DIR/config"
touch "$CONFIG"
chmod 600 "$CONFIG"

if ! grep -q "^Host wukong-pc$" "$CONFIG" 2>/dev/null; then
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
    echo "config 已写入 wukong-pc 段"
else
    echo "config 已有 wukong-pc 段,跳过"
fi

BASHRC="$HOME/.bashrc"
touch "$BASHRC"
if ! grep -q "^alias wpc=" "$BASHRC" 2>/dev/null; then
    cat >> "$BASHRC" <<'EOF'

# ssh-deploy alias
alias wpc='ssh wukong-pc'
EOF
    echo "alias wpc 已写入 ~/.bashrc"
else
    echo "alias wpc 已存在,跳过"
fi

echo ""
echo "============================================"
echo "✅ 部署完成!"
echo "  Termux 里输:  ssh wukong-pc"
echo "  或 alias:     wpc"
echo "  首次会确认 host key (输 yes)"
echo "  然后提示输 Win11 账号密码(每次连都要输)"
echo "============================================"