#!/bin/bash
# ssh-deploy Termux 一键脚本(只装客户端)
#
#   1) 装 OpenSSH Client (pkg install openssh)
#   2) 拉 VPS 主机清单 (Bearer token) → 写 ~/.ssh/config 多 Host wpc-* 段
#   3) 写 ~/.bashrc alias (wpc-<name> = ssh <alias>)
#   4) 主菜单 [1]Install [2]Status [3]Switch [0]Exit
#
# 用法:
#   curl -fsSL https://raw.githubusercontent.com/wukong0908/ssh-deploy/<commit>/termux/ssh-deploy.sh | bash
#   bash ssh-deploy.sh -v 8.163.106.31 -t your_token
#
# 注:
#   stdin 非交互 (curl|bash) 下 read 会失败,脚本默认走 DEFAULT_* 值,不读 stdin.

set -u  # 不 set -e — read 返 1 不能让脚本死
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

DEFAULT_VPS='8.163.106.31'
DEFAULT_VPS_API_PORT=8080
OPENSSH_GH_URL='https://raw.githubusercontent.com/wukong0908/ssh-deploy/main/bin/openssh/OpenSSH-Win64.zip'
# Termux 用不了 Windows 二进制 zip,这里不下载 — pkg install openssh 一行解决

VPS_HOST=""
BEARER_TOKEN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--vps) VPS_HOST="$2"; shift 2 ;;
        -t|--token) BEARER_TOKEN="$2"; shift 2 ;;
        -h|--help)
            echo "用法: $0 [-v VPS_HOST] [-t BEARER_TOKEN]"
            echo "  无参: 进入交互式菜单"
            echo "  传参: 直接 install"
            exit 0
            ;;
        *) echo "未知参数: $1"; exit 1 ;;
    esac
done

SSH_DIR="$HOME/.ssh"
CONFIG_FILE="$SSH_DIR/config"
BASHRC="$HOME/.bashrc"
TMP_DIR="${TMPDIR:-/tmp}/ssh-deploy"

mkdir -p "$SSH_DIR" "$TMP_DIR"

# ---------- 颜色 / 日志 ----------
if [ -t 1 ]; then
    C_CYAN='\033[36m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_RED='\033[31m'; C_OFF='\033[0m'
else
    C_CYAN=''; C_GREEN=''; C_YELLOW=''; C_RED=''; C_OFF=''
fi

log() { printf "${C_CYAN}[ssh-deploy]${C_OFF} %s\n" "$*"; }
ok() { printf "${C_GREEN}✅ %s${C_OFF}\n" "$*"; }
warn() { printf "${C_YELLOW}⚠️  %s${C_OFF}\n" "$*"; }
err() { printf "${C_RED}❌ %s${C_OFF}\n" "$*" >&2; }

step() { printf "\n${C_CYAN}== %s ==${C_OFF}\n" "$*"; }

# ---------- 交互收集(只在 stdin 是 TTY 时才读)----------
collect_interactive() {
    if [ -t 0 ]; then
        printf "VPS 公网 IP [$DEFAULT_VPS]: "
        read -r input
        VPS_HOST="${input:-$DEFAULT_VPS}"
        printf "ssh-deploy-api Bearer token(留空=不调 VPS API): "
        read -r input
        BEARER_TOKEN="${input:-}"
    else
        # stdin 非 TTY(curl|bash)— 直接用默认
        : "${VPS_HOST:=$DEFAULT_VPS}"
        # token 仍可能从外面传(但非交互下推荐传参)
        warn "stdin 非 TTY,使用 -v / -t 传参或 DEFAULT_VPS"
    fi
}

# ---------- 1. OpenSSH Client ----------
install_openssh() {
    step "1/3 OpenSSH Client"
    if command -v ssh >/dev/null 2>&1; then
        log "ssh 已装: $(command -v ssh)"
        return 0
    fi
    log "装 openssh..."
    if ! pkg install -y openssh 2>&1 | tail -5; then
        err "pkg install openssh 失败"
        return 1
    fi
    command -v ssh >/dev/null 2>&1 || { err "装后仍找不到 ssh"; return 1; }
    ok "ssh: $(command -v ssh)"
}

# ---------- 2. 拉 VPS 清单 → 写 SSH config ----------
fetch_vps_hosts() {
    if [ -z "$BEARER_TOKEN" ]; then
        warn "无 Bearer token,跳过 VPS 拉取"
        return 1
    fi
    if [ -z "$VPS_HOST" ]; then
        warn "无 VPS_HOST,跳过"
        return 1
    fi
    local url="http://${VPS_HOST}:${DEFAULT_VPS_API_PORT}/ssh-deploy/hosts"
    log "拉 $url"
    local resp
    resp=$(curl -fsS --max-time 8 -H "Authorization: Bearer $BEARER_TOKEN" "$url" 2>&1) || {
        warn "拉 VPS hosts 失败:$resp"
        return 1
    }
    echo "$resp"
}

# JSON → TSV: 用 grep + sed + paste 拆每个 server 对象,避免依赖 python/jq
# 输入: VPS 返回的 {"servers":[{...},{...}]}
# 输出: 每 4 行 → 1 行 TSV: name\tport\tuser\talias
# vps_host 不输出(所有 server 都走同一 $VPS_HOST,留空字段会触发 bash IFS 空吞 bug)
parse_hosts() {
    echo "$1" | grep -oE '"(name|ssh_port|ssh_user|alias)":[[:space:]]*("[^"]*"|[0-9]+)' \
        | sed -E 's/^"(name|ssh_port|ssh_user|alias)":[[:space:]]*//; s/^"(.*)"$/\1/; s/"$//' \
        | paste - - - -
}

generate_ssh_config() {
    step "2/3 拉 VPS 主机清单 → 写 ~/.ssh/config"
    local json
    json=$(fetch_vps_hosts) || { warn "VPS 拉取失败,SSH config 不写"; return 1; }

    local hosts_tsv
    hosts_tsv=$(parse_hosts "$json") || { err "JSON 解析失败"; return 1; }

    # 备份
    if [ -f "$CONFIG_FILE" ]; then
        cp "$CONFIG_FILE" "$CONFIG_FILE.bak.$(date +%Y%m%d%H%M%S)"
        log "config 已备份"
    fi
    [ -f "$CONFIG_FILE" ] || touch "$CONFIG_FILE"

    # 删旧 ssh-deploy 段(sed 区间地址:从 # ===== ssh-deploy: 到 # ===== END ssh-deploy ===== + 后面空行)
    if [ -s "$CONFIG_FILE" ]; then
        sed -i '/^# ===== ssh-deploy:/,/^# ===== END ssh-deploy =====/d' "$CONFIG_FILE"
        # 删可能残留的连续空行(段间空行)
        sed -i '/^$/N;/^\n$/d' "$CONFIG_FILE"
    fi

    # 写新段
    local count=0
    while IFS=$'\t' read -r name port user alias; do
        [ -z "$name" ] && continue
        local vps="$VPS_HOST"
        local a="${alias:-wpc-$name}"
        cat >> "$CONFIG_FILE" <<EOF

# ===== ssh-deploy: $name =====
Host $a
    HostName $vps
    Port $port
    User $user
    PreferredAuthentications password
    PubkeyAuthentication no
    StrictHostKeyChecking accept-new
    ServerAliveInterval 30
    ServerAliveCountMax 3
    Compression yes
# ===== END ssh-deploy =====
EOF
        ok "  alias $a → $vps:$port user=$user"
        count=$((count + 1))
    done <<< "$hosts_tsv"

    chmod 600 "$CONFIG_FILE"
    ok "写了 $count 个 Host 段"
}

# ---------- 3. bashrc alias ----------
generate_aliases() {
    step "3/3 写 ~/.bashrc alias"
    local json
    json=$(fetch_vps_hosts) || { warn "VPS 拉不到,alias 不写"; return 0; }

    # 删旧 ssh-deploy alias 段
    if [ -f "$BASHRC" ]; then
        sed -i '/^# ===== ssh-deploy aliases/,/^# ===== END ssh-deploy aliases =====/d' "$BASHRC"
        sed -i '/^$/N;/^\n$/d' "$BASHRC"
    fi

    local hosts_tsv
    hosts_tsv=$(parse_hosts "$json")

    {
        printf '\n# ===== ssh-deploy aliases =====\n'
        while IFS=$'\t' read -r name port user alias; do
            [ -z "$name" ] && continue
            local a="${alias:-wpc-$name}"
            printf 'ssh-%s() { ssh %s; }\n' "$name" "$a"
            printf "alias wpc-%s='ssh %s'\n" "$name" "$a"
        done <<< "$hosts_tsv"
        printf '# ===== END ssh-deploy aliases =====\n'
    } >> "$BASHRC"
    ok "alias 段已写"
}

# ---------- Status ----------
show_status() {
    step "Status"
    echo "  主机名: $(hostname)"
    echo "  VPS:    $VPS_HOST"
    echo ""

    if command -v ssh >/dev/null 2>&1; then
        ok "ssh: $(command -v ssh)"
    else
        err "ssh: 未装"
    fi

    if [ -f "$CONFIG_FILE" ]; then
        local n
        n=$(grep -c '^Host wpc-' "$CONFIG_FILE" 2>/dev/null || echo 0)
        echo "  SSH config: $n 个 wpc-* 段"
    else
        warn "SSH config 不存在"
    fi

    if [ -f "$BASHRC" ] && grep -q 'ssh-deploy aliases' "$BASHRC" 2>/dev/null; then
        local an
        an=$(grep -c "^alias wpc-" "$BASHRC" 2>/dev/null || echo 0)
        echo "  bashrc alias: $an 个"
    fi

    # VPS hosts
    echo ""
    echo "--- VPS 主机清单 ---"
    local json
    json=$(fetch_vps_hosts) && {
        parse_hosts "$json" | awk -F'\t' '{ printf "  %-12s port %-5s user %-10s alias %s\n", $1, $2, $3, $4 }'
    } || warn "  (无 / 拉不到)"
}

# ---------- Switch (重拉清单)----------
switch_alias() {
    log "重拉 VPS 清单 + 重写 config + bashrc alias"
    generate_ssh_config
    generate_aliases
    ok "switch 完成。重开 Termux 或 source ~/.bashrc 生效"
}

# ---------- 主菜单 ----------
show_menu() {
    while true; do
        printf "\n${C_CYAN}========== ssh-deploy (Android) =========${C_OFF}\n"
        printf "  [1] Install (client only)\n"
        printf "  [2] Status\n"
        printf "  [3] Switch (重拉 VPS 清单)\n"
        printf "  [0] Exit\n"
        printf "${C_CYAN}=========================================${C_OFF}\n"
        printf "选择 [0-3]: "
        read -r choice || return 0
        case "$choice" in
            1) install_openssh && generate_ssh_config && generate_aliases ;;
            2) show_status ;;
            3) switch_alias ;;
            0) return 0 ;;
            *) warn "无效输入" ;;
        esac
    done
}

# ---------- 主入口 ----------
if [ -n "$VPS_HOST" ] || [ -n "$BEARER_TOKEN" ] || [ $# -gt 0 ]; then
    # 传参 → 直跑
    collect_interactive
    install_openssh
    generate_ssh_config
    generate_aliases
else
    # 无参 → 菜单(只在 TTY 下有意义)
    if [ -t 0 ]; then
        collect_interactive
        show_menu
    else
        # stdin 非 TTY 又没传参 → 直跑 default
        warn "stdin 非 TTY 且无参,直跑 default install"
        collect_interactive
        install_openssh
        generate_ssh_config
        generate_aliases
    fi
fi