#!/data/data/com.termux/files/usr/bin/bash
# deploy-android.sh
# Termux 一键部署 SSH client,使 Android 通过 FRP VPS 连回本机 Win11。
# 私钥通过 base64 编码后粘贴,脚本一次性解码还原(不分行,不被终端截断)。

set -e

DEFAULT_VPS="8.163.106.31"
DEFAULT_PORT=6000
DEFAULT_KEY_NAME="id_ed25519"

# ---------- 0. Termux 环境检查 ----------
if [ ! -d "/data/data/com.termux" ]; then
    echo "❌ 这个脚本必须在 Termux 里跑。"
    exit 1
fi

# ---------- 1. 装 openssh / git ----------
echo "[1/5] 安装 openssh / git..."
pkg update -y >/dev/null 2>&1 || true
pkg install -y openssh git coreutils >/dev/null 2>&1 || true
# coreutils 给 base64

# ---------- 2. 准备 ~/.ssh ----------
echo "[2/5] 准备 ~/.ssh"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# ---------- 3. 交互收集 ----------
read -rp "VPS 公网 IP 或域名 [${DEFAULT_VPS}]: " VPS_HOST
VPS_HOST=${VPS_HOST:-$DEFAULT_VPS}

read -rp "FRP 转发的 SSH 端口 [${DEFAULT_PORT}]: " SSH_PORT
SSH_PORT=${SSH_PORT:-$DEFAULT_PORT}

read -rp "本机 Win11 的 SSH 用户名 (例如 WuKong): " LOCAL_USER

read -rp "私钥文件名 [${DEFAULT_KEY_NAME}]: " KEY_NAME
KEY_NAME=${KEY_NAME:-$DEFAULT_KEY_NAME}
KEY_PATH="$HOME/.ssh/$KEY_NAME"

# ---------- 4. 粘贴私钥(base64,单行) ----------
cat <<'TIP'

[3/5] 现在粘贴私钥的 base64 编码(单行)
       主控端生成:  base64 -w0 ~/.ssh/id_ed25519
       把输出的一长串字符粘贴进来,按回车结束。

TIP

KEY_B64=""
# 从 /dev/tty 读
exec 3</dev/tty 2>/dev/null || exec 3<&0
FIRST=1
while IFS= read -r line <&3; do
    # 去 CR 和所有空白
    line=$(printf '%s' "$line" | tr -d '\r' | tr -d ' \t\n')
    if [ $FIRST -eq 1 ] && [ -z "$line" ]; then continue; fi
    FIRST=0
    if [ -z "$line" ]; then break; fi
    KEY_B64="${KEY_B64}${line}"
done
exec 3<&- 2>/dev/null || true

# 解码
KEY_CONTENT=$(printf '%s' "$KEY_B64" | base64 -d 2>/dev/null) || {
    echo "❌ base64 解码失败(检查输入是否完整)"
    exit 1
}

# 校验
if ! echo "$KEY_CONTENT" | grep -q "-----BEGIN .* PRIVATE KEY-----"; then
    echo "❌ 解码后没看到 BEGIN 标记。输入有误或截断了。"
    exit 1
fi
if ! echo "$KEY_CONTENT" | grep -q "-----END .* PRIVATE KEY-----"; then
    echo "❌ 解码后没看到 END 标记。"
    exit 1
fi

echo "$KEY_CONTENT" > "$KEY_PATH"
chmod 600 "$KEY_PATH"
echo "私钥已写 $KEY_PATH"

# ---------- 5. 校验 + 写 config ----------
echo "[4/5] 校验私钥 + 写 ~/.ssh/config"
if ssh-keygen -y -f "$KEY_PATH" -P "" >/dev/null 2>&1; then
    echo "✅ 私钥 OK,公钥指纹:"
    ssh-keygen -l -f "$KEY_PATH"
else
    echo "⚠️  私钥校验失败(可能带 passphrase)。首次连接 ssh 会要求输入。"
fi

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

# ---------- 6. alias ----------
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
echo "  Termux 里输:  ssh wukong-pc"
echo "  或 alias:     wpc"
echo "  首次连会确认 host key,输 yes 后即可登录。"
echo "============================================"