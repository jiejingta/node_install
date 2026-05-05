#!/usr/bin/env bash
#
# HY2 节点一键部署脚本
# 适用于 Ubuntu 20.04 / 22.04 / 24.04 与对应 Debian 系统
#
# 功能：
#   1. 安装官方 Hysteria2 并生成配置、启动服务
#   2. 配置 nftables 端口跳跃转发
#   3. 安装 fail2ban 防止 SSH 爆破
#   4. 默认开启 BBR 拥塞控制
#   5. 输出客户端连接配置
#
set -euo pipefail

# ============ 固定配置 ============
HY2_PORT=54000
HY2_PASSWORD="RkMi0BPuVz"
HY2_SNI="www.bing.com"
HOP_START=50001
HOP_END=53999
# ==================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ============ 前置检查 ============
[[ $EUID -ne 0 ]] && error "请以 root 身份运行"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "系统: ${PRETTY_NAME}"
else
    warn "无法检测系统版本，继续执行"
fi

SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me || curl -4 -s --max-time 5 ip.sb || echo "YOUR_SERVER_IP")

wait_for_apt_lock() {
    local timeout="${1:-300}"
    local waited=0

    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 \
       || fuser /var/lib/dpkg/lock >/dev/null 2>&1 \
       || fuser /var/lib/apt/lists/lock >/dev/null 2>&1; do
        if (( waited >= timeout )); then
            return 1
        fi
        sleep 3
        waited=$((waited + 3))
    done

    return 0
}

# ============================================================
# 1. 安装 Hysteria2
# ============================================================
install_hysteria2() {
    info "========== 安装 Hysteria2 =========="

    # 如果已安装先清理
    if command -v hysteria &>/dev/null; then
        warn "检测到已有 Hysteria2，先卸载"
        systemctl stop hysteria-server 2>/dev/null || true
        systemctl disable hysteria-server 2>/dev/null || true
        bash <(curl -fsSL https://get.hy2.sh/) --remove 2>/dev/null || true
        rm -rf /etc/hysteria
        userdel -r hysteria 2>/dev/null || true
        rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service
        rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
        systemctl daemon-reload
    fi

    # 安装官方二进制
    bash <(curl -fsSL https://get.hy2.sh/)

    # 生成自签证书
    info "生成自签证书 (CN=${HY2_SNI})"
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/server.key -out /etc/hysteria/server.crt \
        -subj "/CN=${HY2_SNI}" -days 3650 2>/dev/null
    chmod 644 /etc/hysteria/server.key /etc/hysteria/server.crt

    # 写入配置
    info "写入配置文件"
    cat > /etc/hysteria/config.yaml << EOF
listen: :${HY2_PORT}

tls:
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key

auth:
  type: password
  password: ${HY2_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: https://${HY2_SNI}
    rewriteHost: true
EOF

    # 启动
    systemctl enable --now hysteria-server
    sleep 1

    if systemctl is-active --quiet hysteria-server; then
        info "Hysteria2 启动成功"
    else
        error "Hysteria2 启动失败，请检查: journalctl -u hysteria-server --no-pager -n 20"
    fi
}

# ============================================================
# 2. 配置 nftables 端口跳跃
# ============================================================
setup_port_hopping() {
    info "========== 配置端口跳跃 =========="

    # 安装 nftables
    if ! command -v nft &>/dev/null; then
        info "安装 nftables"
        apt-get update -qq
        apt-get install -y nftables >/dev/null 2>&1
    fi

    # 探测网卡
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [[ -z "$iface" ]]; then
        iface=$(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -vE '^(lo|docker|br-|veth)' | head -1)
    fi
    [[ -z "$iface" ]] && error "未检测到可用网卡"
    info "使用网卡: ${iface}"

    # 清理旧规则
    nft list table ip hysteria_hop &>/dev/null 2>&1 && nft delete table ip hysteria_hop

    # 创建规则
    nft add table ip hysteria_hop
    nft add chain ip hysteria_hop prerouting '{ type nat hook prerouting priority dstnat; }'
    nft add rule ip hysteria_hop prerouting iif "$iface" udp dport ${HOP_START}-${HOP_END} counter dnat to :${HY2_PORT}
    info "已配置: UDP ${HOP_START}-${HOP_END} → ${HY2_PORT}"

    # 持久化
    local conf_dir="/etc/nftables.d"
    mkdir -p "$conf_dir"
    cat > "${conf_dir}/hysteria-hop.conf" << EOF
#!/usr/sbin/nft -f
# 端口跳跃转发 — 自动生成于 $(date '+%Y-%m-%d %H:%M:%S')
table ip hysteria_hop {
    chain prerouting {
        type nat hook prerouting priority dstnat;
        iif ${iface} udp dport ${HOP_START}-${HOP_END} counter dnat to :${HY2_PORT}
    }
}
EOF

    # 确保 nftables.conf 包含 include
    local main_conf="/etc/nftables.conf"
    if [[ ! -f "$main_conf" ]]; then
        cat > "$main_conf" << 'EOF2'
#!/usr/sbin/nft -f
flush ruleset
include "/etc/nftables.d/*.conf"
EOF2
    elif ! grep -q '/etc/nftables.d/\*\.conf' "$main_conf" 2>/dev/null; then
        echo '' >> "$main_conf"
        echo 'include "/etc/nftables.d/*.conf"' >> "$main_conf"
    fi

    systemctl enable nftables >/dev/null 2>&1 || true
    info "端口跳跃配置完成并已持久化"
}

# ============================================================
# 3. 安装 fail2ban
# ============================================================
setup_fail2ban() {
    info "========== 安装 fail2ban =========="

    if command -v fail2ban-client &>/dev/null; then
        info "fail2ban 已安装，跳过"
    else
        info "安装 fail2ban（若失败将跳过，不中断后续部署）"
        if ! wait_for_apt_lock 300; then
            warn "apt/dpkg 锁长期被占用，跳过 fail2ban 安装"
            return 0
        fi
        if ! DEBIAN_FRONTEND=noninteractive apt-get update -qq; then
            warn "apt-get update 失败，跳过 fail2ban 安装"
            return 0
        fi
        if ! wait_for_apt_lock 300; then
            warn "apt/dpkg 锁长期被占用，跳过 fail2ban 安装"
            return 0
        fi
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y fail2ban; then
            warn "fail2ban 安装失败，跳过该步骤"
            return 0
        fi
    fi

    # SSH 防爆破配置
    cat > /etc/fail2ban/jail.local << 'EOF'
[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 5
findtime = 600
bantime  = 3600
EOF

    if systemctl enable --now fail2ban && systemctl restart fail2ban; then
        info "fail2ban 已启动，SSH 连续失败 5 次将封禁 1 小时"
    else
        warn "fail2ban 服务启动失败，请手动检查: journalctl -u fail2ban --no-pager -n 20"
    fi
}

# ============================================================
# 4. 防火墙放行
# ============================================================
setup_firewall() {
    info "========== 防火墙放行 =========="

    if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
        ufw allow ${HY2_PORT}/udp >/dev/null 2>&1
        ufw allow ${HOP_START}:${HOP_END}/udp >/dev/null 2>&1
        info "ufw 已放行 UDP ${HOP_START}-${HOP_END} 和 ${HY2_PORT}"
    else
        # 直接用 iptables 兜底
        iptables -C INPUT -p udp --dport ${HY2_PORT} -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport ${HY2_PORT} -j ACCEPT
        iptables -C INPUT -p udp --dport ${HOP_START}:${HOP_END} -j ACCEPT 2>/dev/null || \
            iptables -I INPUT -p udp --dport ${HOP_START}:${HOP_END} -j ACCEPT
        info "iptables 已放行 UDP ${HOP_START}-${HOP_END} 和 ${HY2_PORT}"
    fi
}


# ============================================================
# 5. 开启 BBR
# ============================================================
setup_bbr() {
    info "========== 开启 BBR =========="

    if ! grep -q '^net.core.default_qdisc=fq$' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf
    fi

    if ! grep -q '^net.ipv4.tcp_congestion_control=bbr$' /etc/sysctl.conf 2>/dev/null; then
        echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf
    fi

    modprobe tcp_bbr 2>/dev/null || true
    sysctl -p >/dev/null 2>&1 || true

    local qdisc cc
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)

    if [[ "$cc" == "bbr" ]]; then
        info "BBR 已开启 (qdisc=${qdisc}, congestion_control=${cc})"
    else
        warn "BBR 设置未生效，当前 congestion_control=${cc}"
    fi
}

# ============================================================
# 执行
# ============================================================
install_hysteria2
setup_port_hopping
setup_fail2ban
setup_firewall
setup_bbr

# ============================================================
# 6. 输出客户端配置
# ============================================================
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${GREEN}${BOLD}  部署完成！${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  ${BOLD}服务状态:${NC}"
echo -e "    Hysteria2  $(systemctl is-active hysteria-server)"
echo -e "    fail2ban   $(systemctl is-active fail2ban)"
echo -e "    nftables   $(systemctl is-enabled nftables 2>/dev/null || echo 'unknown')"
echo ""
echo -e "  ${BOLD}端口跳跃:${NC}"
echo -e "    UDP ${CYAN}${HOP_START}-${HOP_END}${NC} → ${GREEN}${HY2_PORT}${NC}"
echo ""
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  sing-box 客户端 outbound 配置${NC}"
echo -e "${BOLD}================================================================${NC}"
cat << EOF

{
  "type": "hysteria2",
  "tag": "hy2-${SERVER_IP##*.}",
  "server": "${SERVER_IP}",
  "server_ports": [
    "${HOP_START}:${HOP_END}"
  ],
  "hop_interval": "30s",
  "up_mbps": 20,
  "down_mbps": 20,
  "password": "${HY2_PASSWORD}",
  "tls": {
    "enabled": true,
    "server_name": "${HY2_SNI}",
    "insecure": true,
    "alpn": ["h3"]
  }
}

EOF
echo -e "${BOLD}================================================================${NC}"
echo -e "${BOLD}  通用 Hysteria2 URI（可导入各类客户端）${NC}"
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  ${CYAN}hy2://${HY2_PASSWORD}@${SERVER_IP}:${HOP_START}?insecure=1&sni=${HY2_SNI}&mport=${HOP_START}-${HOP_END}#hy2-${SERVER_IP##*.}${NC}"
echo ""
echo -e "${BOLD}================================================================${NC}"
echo ""
echo -e "  ${YELLOW}提醒:${NC} 如果是云服务器，请确保安全组已放行 UDP ${HOP_START}-${HOP_END}"
echo ""
