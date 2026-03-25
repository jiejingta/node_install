#!/usr/bin/env bash
#
# nft-port-hop — nftables UDP 端口跳跃转发一键配置
# 适用于 Ubuntu 20.04 / 22.04 / 24.04 及 Debian 10+
# 用法: bash <(curl -Ls https://raw.githubusercontent.com/<you>/nft-port-hop/main/install.sh)
#

set -euo pipefail

# ============================================================
# 颜色与输出
# ============================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }
ask()   { echo -en "${CYAN}[ASK]${NC}  $*"; }

# ============================================================
# 前置检查
# ============================================================
if [[ $EUID -ne 0 ]]; then
    error "请以 root 身份运行此脚本"
    exit 1
fi

# 检查发行版
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "检测到系统: ${PRETTY_NAME:-$ID $VERSION_ID}"
else
    warn "无法检测系统版本，继续执行……"
fi

# ============================================================
# 安装 nftables（如果缺失）
# ============================================================
install_nftables() {
    if command -v nft &>/dev/null; then
        info "nftables 已安装: $(nft --version)"
        return 0
    fi

    info "正在安装 nftables……"
    apt-get install -y nftables >/dev/null 2>&1 || {
        error "安装 nftables 失败，请手动执行: apt-get install -y nftables"
        exit 1
    }
    info "nftables 安装完成: $(nft --version)"
}

install_nftables

# ============================================================
# 网卡探测
# ============================================================
detect_interface() {
    # 获取默认路由对应网卡
    local default_iface
    default_iface=$(ip -4 route show default 2>/dev/null | awk '{print $5; exit}')

    # 列出所有非 lo、非 docker/veth/br 的物理/虚拟网卡
    local all_ifaces=()
    while IFS= read -r line; do
        all_ifaces+=("$line")
    done < <(ip -o link show | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -vE '^(lo|docker|br-|veth)')

    if [[ ${#all_ifaces[@]} -eq 0 ]]; then
        error "未检测到可用网卡"
        exit 1
    fi

    echo ""
    info "检测到以下网卡:"
    echo ""
    for i in "${!all_ifaces[@]}"; do
        local iface="${all_ifaces[$i]}"
        local addr
        addr=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -1)
        local marker=""
        if [[ "$iface" == "$default_iface" ]]; then
            marker=" ${GREEN}<— 默认路由${NC}"
        fi
        echo -e "  ${BOLD}$((i + 1)))${NC} ${iface}  ${addr:-无IPv4}${marker}"
    done
    echo ""

    if [[ ${#all_ifaces[@]} -eq 1 ]]; then
        IFACE="${all_ifaces[0]}"
        info "仅有一张网卡，自动选择: ${BOLD}${IFACE}${NC}"
        return 0
    fi

    # 如果有默认路由网卡，推荐它
    if [[ -n "$default_iface" ]]; then
        ask "请选择网卡 [回车默认 ${BOLD}${default_iface}${NC}]: "
        read -r choice
        if [[ -z "$choice" ]]; then
            IFACE="$default_iface"
            info "已选择: ${BOLD}${IFACE}${NC}"
            return 0
        fi
    else
        ask "请选择网卡编号: "
        read -r choice
    fi

    # 按编号选择
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#all_ifaces[@]} )); then
        IFACE="${all_ifaces[$((choice - 1))]}"
    else
        # 按名称选择
        local found=0
        for iface in "${all_ifaces[@]}"; do
            if [[ "$iface" == "$choice" ]]; then
                IFACE="$iface"
                found=1
                break
            fi
        done
        if [[ $found -eq 0 ]]; then
            error "无效选择: $choice"
            exit 1
        fi
    fi
    info "已选择: ${BOLD}${IFACE}${NC}"
}

IFACE=""
detect_interface

# ============================================================
# 规则收集
# ============================================================
declare -a RULES=()   # 每条规则格式: "start_port-end_port:target_port"

validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
        return 0
    fi
    return 1
}

# 检查端口范围是否与已有规则冲突
check_conflict() {
    local new_start="$1"
    local new_end="$2"
    local new_target="$3"

    for rule in "${RULES[@]}"; do
        local range="${rule%%:*}"
        local existing_target="${rule##*:}"
        local existing_start="${range%%-*}"
        local existing_end="${range##*-}"

        # 检查转发目标端口是否落在某条规则的源范围内
        if (( new_target >= existing_start && new_target <= existing_end )); then
            echo "转发目标端口 ${new_target} 落在已有规则 ${existing_start}-${existing_end} 的范围内"
            return 1
        fi

        # 检查已有规则的目标端口是否落在新规则的源范围内
        if (( existing_target >= new_start && existing_target <= new_end )); then
            echo "已有规则的目标端口 ${existing_target} 落在新规则 ${new_start}-${new_end} 的范围内"
            return 1
        fi

        # 检查源端口范围重叠
        if (( new_start <= existing_end && new_end >= existing_start )); then
            echo "端口范围 ${new_start}-${new_end} 与已有规则 ${existing_start}-${existing_end} 重叠"
            return 1
        fi

        # 检查新的转发目标与已有转发目标相同（不同范围转给同一端口通常是ok的，但提示一下）
    done

    # 检查目标端口是否在自己的源范围内
    if (( new_target >= new_start && new_target <= new_end )); then
        echo "转发目标端口 ${new_target} 不能在源范围 ${new_start}-${new_end} 内"
        return 1
    fi

    return 0
}

add_rule_interactive() {
    local start_port end_port target_port

    while true; do
        echo ""
        ask "请输入源端口范围起始 (如 50001): "
        read -r start_port
        if ! validate_port "$start_port"; then
            error "无效端口: $start_port (需要 1-65535)"
            continue
        fi

        ask "请输入源端口范围结束 (如 53999): "
        read -r end_port
        if ! validate_port "$end_port"; then
            error "无效端口: $end_port (需要 1-65535)"
            continue
        fi

        if (( start_port >= end_port )); then
            error "起始端口必须小于结束端口"
            continue
        fi

        ask "请输入转发目标端口 (如 54999): "
        read -r target_port
        if ! validate_port "$target_port"; then
            error "无效端口: $target_port (需要 1-65535)"
            continue
        fi

        local conflict
        conflict=$(check_conflict "$start_port" "$end_port" "$target_port") || {
            error "配置冲突: $conflict"
            continue
        }

        RULES+=("${start_port}-${end_port}:${target_port}")
        info "已添加规则: UDP ${start_port}-${end_port} → ${target_port}"
        break
    done
}

collect_rules() {
    echo ""
    echo -e "${BOLD}================================================${NC}"
    echo -e "${BOLD}  配置端口跳跃转发规则${NC}"
    echo -e "${BOLD}================================================${NC}"
    echo ""
    echo -e "  默认配置包含以下规则:"
    echo ""
    echo -e "  ${CYAN}1)${NC} UDP 50001-53999 → 54999  ${YELLOW}(Hysteria2)${NC}"
    echo -e "  ${CYAN}2)${NC} UDP 40001-43999 → 44999  ${YELLOW}(Hysteria1)${NC}"
    echo ""

    ask "是否使用默认配置？[Y/n]: "
    read -r use_default

    if [[ -z "$use_default" || "$use_default" =~ ^[Yy]$ ]]; then
        # 默认规则
        RULES+=("50001-53999:54999")
        RULES+=("40001-43999:44999")
        info "已加载默认配置 (2 条规则)"
    else
        info "进入自定义配置模式"
        add_rule_interactive

        while true; do
            echo ""
            ask "是否继续添加规则？[y/N]: "
            read -r more
            if [[ "$more" =~ ^[Yy]$ ]]; then
                add_rule_interactive
            else
                break
            fi
        done
    fi

    # 最终确认
    echo ""
    info "即将应用以下规则 (网卡: ${BOLD}${IFACE}${NC}):"
    echo ""
    for rule in "${RULES[@]}"; do
        local range="${rule%%:*}"
        local target="${rule##*:}"
        echo -e "  ${GREEN}✓${NC} UDP ${range} → ${target}"
    done
    echo ""
    ask "确认执行？[Y/n]: "
    read -r confirm
    if [[ "$confirm" =~ ^[Nn]$ ]]; then
        info "已取消"
        exit 0
    fi
}

collect_rules

# ============================================================
# 清理旧配置（如果存在）
# ============================================================
cleanup_old() {
    if nft list table ip hysteria_hop &>/dev/null 2>&1; then
        warn "检测到已有 hysteria_hop 表，正在清理……"
        nft delete table ip hysteria_hop
        info "旧配置已清理"
    fi
}

cleanup_old

# ============================================================
# 应用 nftables 规则
# ============================================================
apply_rules() {
    info "正在创建 nftables 规则……"

    nft add table ip hysteria_hop
    nft add chain ip hysteria_hop prerouting '{ type nat hook prerouting priority dstnat; }'

    for rule in "${RULES[@]}"; do
        local range="${rule%%:*}"
        local target="${rule##*:}"
        local start="${range%%-*}"
        local end="${range##*-}"

        nft add rule ip hysteria_hop prerouting iif "$IFACE" udp dport "$start"-"$end" counter dnat to :"$target"
        info "已应用: UDP ${start}-${end} → ${target}"
    done
}

apply_rules

# ============================================================
# 持久化
# ============================================================
persist_rules() {
    local conf_dir="/etc/nftables.d"
    local conf_file="${conf_dir}/hysteria-hop.conf"
    local main_conf="/etc/nftables.conf"

    mkdir -p "$conf_dir"

    info "正在写入持久化配置: ${conf_file}"

    {
        echo "#!/usr/sbin/nft -f"
        echo ""
        echo "# 端口跳跃转发规则 — 由 nft-port-hop 脚本生成"
        echo "# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# 网卡: ${IFACE}"
        echo ""
        echo "table ip hysteria_hop {"
        echo "    chain prerouting {"
        echo "        type nat hook prerouting priority dstnat;"
        for rule in "${RULES[@]}"; do
            local range="${rule%%:*}"
            local target="${rule##*:}"
            local start="${range%%-*}"
            local end="${range##*-}"
            echo "        iif ${IFACE} udp dport ${start}-${end} counter dnat to :${target}"
        done
        echo "    }"
        echo "}"
    } > "$conf_file"

    chmod 644 "$conf_file"

    # 确保 main conf 存在且包含 include
    if [[ ! -f "$main_conf" ]]; then
        {
            echo "#!/usr/sbin/nft -f"
            echo "flush ruleset"
            echo "include \"${conf_dir}/*.conf\""
        } > "$main_conf"
    elif ! grep -q "${conf_dir}/\*\.conf" "$main_conf" 2>/dev/null; then
        # 追加 include（避免重复）
        echo "" >> "$main_conf"
        echo "# nft-port-hop 自动添加" >> "$main_conf"
        echo "include \"${conf_dir}/*.conf\"" >> "$main_conf"
    fi

    # 处理 flush ruleset 与独立 table 的冲突
    # 如果 main conf 里有 flush ruleset，我们的文件需要在 flush 之后加载
    # include 在 flush 之后就能正常工作

    # 启用 nftables 服务
    systemctl enable nftables >/dev/null 2>&1 || true
    systemctl restart nftables >/dev/null 2>&1 || true

    info "持久化完成，重启后规则自动生效"
}

persist_rules

# ============================================================
# 验证
# ============================================================
verify() {
    echo ""
    info "验证当前 nftables 规则:"
    echo ""
    nft list table ip hysteria_hop
    echo ""

    # 快速检查 nftables 服务状态
    if systemctl is-enabled nftables &>/dev/null; then
        info "nftables 服务: ${GREEN}已启用 (开机自启)${NC}"
    else
        warn "nftables 服务未设为开机自启，请手动执行: systemctl enable nftables"
    fi
}

verify

# ============================================================
# 提示
# ============================================================
echo ""
echo -e "${BOLD}================================================${NC}"
echo -e "${GREEN}${BOLD}  配置完成！${NC}"
echo -e "${BOLD}================================================${NC}"
echo ""
echo -e "  已配置的转发规则:"
for rule in "${RULES[@]}"; do
    range="${rule%%:*}"
    target="${rule##*:}"
    echo -e "    UDP ${CYAN}${range}${NC} → ${GREEN}${target}${NC}"
done
echo ""
echo -e "  ${BOLD}常用命令:${NC}"
echo -e "    查看规则    ${CYAN}nft list table ip hysteria_hop${NC}"
echo -e "    查看计数    ${CYAN}nft list ruleset | grep counter${NC}"
echo -e "    删除所有    ${CYAN}nft delete table ip hysteria_hop${NC}"
echo -e "    配置文件    ${CYAN}/etc/nftables.d/hysteria-hop.conf${NC}"
echo ""
echo -e "  ${YELLOW}提醒:${NC} 如果是云服务器，请确保安全组/防火墙已放行对应 UDP 端口范围"
echo ""
