#!/bin/bash
set -euo pipefail

# 权限强制检查：必须root运行（读取PowerDNS配置文件需要root权限）
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m 此脚本必须以root用户运行，请使用sudo或切换root后执行"
    exit 1
fi

# 终端颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 日志输出函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_title() { echo -e "\n${BLUE}===== $1 =====${NC}"; }

# 全局变量定义
PDNS_CONF="/etc/powerdns/pdns.conf"
OS=""
VERSION_ID=""
PKG_MANAGER=""

# 系统发行版检测（适配防火墙、服务管理命令）
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测系统发行版，仅支持Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux系列"
        exit 1
    fi
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
}

# 防火墙端口检查函数
check_firewall_port() {
    local PORT=$1
    local PORT_OPEN=0
    log_info "正在检查防火墙 $PORT 端口放行情况..."

    # Debian/Ubuntu 适配 ufw
    if [[ $OS == "debian" || $OS == "ubuntu" ]]; then
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            if ufw status | grep -q "$PORT/tcp"; then
                PORT_OPEN=1
            fi
        else
            log_warn "未检测到启用的ufw防火墙，跳过检查"
            PORT_OPEN=2
        fi
    # RHEL系 适配 firewalld
    elif [[ $OS == "centos" || $OS == "rhel" || $OS == "rocky" || $OS == "almalinux" ]]; then
        if command -v firewalld &>/dev/null && systemctl is-active --quiet firewalld; then
            if firewall-cmd --list-ports | grep -q "$PORT/tcp"; then
                PORT_OPEN=1
            fi
        else
            log_warn "未检测到启用的firewalld防火墙，跳过检查"
            PORT_OPEN=2
        fi
    fi

    # 输出结果
    if [[ $PORT_OPEN -eq 1 ]]; then
        log_info "防火墙已放行 $PORT/tcp 端口"
    elif [[ $PORT_OPEN -eq 0 ]]; then
        log_warn "防火墙未放行 $PORT/tcp 端口，外部网络无法访问API"
    fi
}

# 一键配置并开启PowerDNS API功能
auto_config_api() {
    log_title "PowerDNS API 一键配置"
    log_warn "此操作将修改PowerDNS配置文件、开启API功能、生成强密钥、重启PowerDNS服务"
    read -p "是否确认继续？请输入 yes 确认：" CONFIRM
    [[ $CONFIRM != "yes" ]] && { log_info "已取消API配置操作"; return; }

    # 1. 备份原配置文件
    local BAK_FILE="${PDNS_CONF}.bak.api.$(date +%Y%m%d%H%M%S)"
    cp "$PDNS_CONF" "$BAK_FILE"
    log_info "已备份原配置文件至：$BAK_FILE"

    # 2. 生成强API密钥
    local NEW_API_KEY=$(openssl rand -hex 32)
    log_info "已生成32位强API密钥"

    # 3. 清理原有重复的API/WebServer配置（避免冲突）
    sed -i '/^webserver=/d' "$PDNS_CONF"
    sed -i '/^webserver-address=/d' "$PDNS_CONF"
    sed -i '/^webserver-port=/d' "$PDNS_CONF"
    sed -i '/^webserver-allow-from=/d' "$PDNS_CONF"
    sed -i '/^api=/d' "$PDNS_CONF"
    sed -i '/^api-key=/d' "$PDNS_CONF"
    sed -i '/^allow-from=/d' "$PDNS_CONF"

    # 4. 询问监听配置
    read -p "请输入API监听地址（默认0.0.0.0，监听所有网卡）：" LISTEN_ADDR
    LISTEN_ADDR=${LISTEN_ADDR:-0.0.0.0}
    read -p "请输入API监听端口（默认8081）：" LISTEN_PORT
    LISTEN_PORT=${LISTEN_PORT:-8081}
    read -p "请输入允许访问API的IP段（默认127.0.0.0/8,::1/128，仅本地访问）：" ALLOW_FROM
    ALLOW_FROM=${ALLOW_FROM:-127.0.0.0/8,::1/128}

    # 5. 写入新配置
    cat >> "$PDNS_CONF" <<EOF

# PowerDNS API 配置（脚本自动生成）
webserver=yes
webserver-address=$LISTEN_ADDR
webserver-port=$LISTEN_PORT
webserver-allow-from=$ALLOW_FROM
api=yes
api-key=$NEW_API_KEY
allow-from=127.0.0.0/8,::1/128
EOF
    log_info "API配置已写入PowerDNS配置文件"

    # 6. 重启PowerDNS服务使配置生效
    log_info "正在重启PowerDNS服务使配置生效..."
    if systemctl restart pdns; then
        log_info "PowerDNS服务重启成功，配置已生效"
    else
        log_error "PowerDNS重启失败，请检查配置文件：$PDNS_CONF"
        log_error "可执行以下命令恢复原配置：cp $BAK_FILE $PDNS_CONF && systemctl restart pdns"
        exit 1
    fi

    # 7. 防火墙配置
    read -p "是否自动在防火墙放行 $LISTEN_PORT/tcp 端口？(yes/no，默认yes)：" OPEN_PORT
    OPEN_PORT=${OPEN_PORT:-yes}
    if [[ $OPEN_PORT == "yes" ]]; then
        if [[ $OS == "debian" || $OS == "ubuntu" ]]; then
            if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                ufw allow "$LISTEN_PORT/tcp"
                ufw reload
                log_info "已在ufw防火墙放行 $LISTEN_PORT/tcp 端口"
            fi
        elif [[ $OS == "centos" || $OS == "rhel" || $OS == "rocky" || $OS == "almalinux" ]]; then
            if command -v firewalld &>/dev/null && systemctl is-active --quiet firewalld; then
                firewall-cmd --permanent --add-port="$LISTEN_PORT/tcp"
                firewall-cmd --reload
                log_info "已在firewalld防火墙放行 $LISTEN_PORT/tcp 端口"
            fi
        fi
    fi

    # 8. 输出配置结果
    log_title "API配置完成，核心信息如下"
    echo -e "API监听地址：${GREEN}$LISTEN_ADDR${NC}"
    echo -e "API监听端口：${GREEN}$LISTEN_PORT${NC}"
    echo -e "API访问密钥：${GREEN}$NEW_API_KEY${NC}"
    echo -e "允许访问IP段：${GREEN}$ALLOW_FROM${NC}"
    echo -e "本地API访问地址：${GREEN}http://127.0.0.1:$LISTEN_PORT${NC}"
    if [[ $LISTEN_ADDR == "0.0.0.0" ]]; then
        SERVER_IPS=$(hostname -I | xargs)
        echo -e "服务器网卡IP：${GREEN}$SERVER_IPS${NC}"
        echo -e "内网/公网访问地址：http://服务器IP:$LISTEN_PORT"
    fi
    log_warn "【安全提醒】请妥善保管API密钥，严格限制允许访问的IP段，避免API泄露！"
}

# 核心功能：获取并输出PowerDNS API完整信息
get_pdns_api_info() {
    log_title "PowerDNS API 信息获取"

    # 1. 检查配置文件是否存在
    if [[ ! -f $PDNS_CONF ]]; then
        log_error "未找到PowerDNS配置文件：$PDNS_CONF"
        log_error "请确认已正确安装PowerDNS服务，再执行此脚本"
        exit 1
    fi
    log_info "检测到PowerDNS配置文件：$PDNS_CONF"

    # 2. 检查PowerDNS服务状态
    log_title "PowerDNS 服务状态"
    if systemctl is-active --quiet pdns; then
        log_info "PowerDNS服务状态：${GREEN}运行中${NC}"
        if systemctl is-enabled --quiet pdns; then
            log_info "PowerDNS开机自启：${GREEN}已开启${NC}"
        else
            log_warn "PowerDNS开机自启：已关闭"
        fi
    else
        log_warn "PowerDNS服务状态：${RED}已停止${NC}"
        log_warn "配置信息仅为文件读取结果，服务未运行时API无法访问"
    fi

    # 3. 提取API核心配置
    log_title "API/WebServer 核心配置"
    # 提取配置项（仅匹配非注释的行首配置，忽略注释内容）
    API_ENABLED=$(grep -w '^api=' "$PDNS_CONF" | awk -F= '{print $2}' | xargs 2>/dev/null || echo "no")
    WEBSERVER_ENABLED=$(grep -w '^webserver=' "$PDNS_CONF" | awk -F= '{print $2}' | xargs 2>/dev/null || echo "no")
    WEBSERVER_ADDRESS=$(grep -w '^webserver-address=' "$PDNS_CONF" | awk -F= '{print $2}' | xargs 2>/dev/null || echo "127.0.0.1（默认值）")
    WEBSERVER_PORT=$(grep -w '^webserver-port=' "$PDNS_CONF" | awk -F= '{print $2}' | xargs 2>/dev/null || echo "8081（默认值）")
    API_KEY=$(grep -w '^api-key=' "$PDNS_CONF" | awk -F= '{print $2}' | xargs 2>/dev/null || echo "")
    WEBSERVER_ALLOW_FROM=$(grep -w '^webserver-allow-from=' "$PDNS_CONF" | awk -F= '{print $2}' | xargs 2>/dev/null || echo "127.0.0.0/8,::1/128（默认值）")

    # 输出配置信息，高亮关键状态
    echo -e "API功能开关：$([[ $API_ENABLED == "yes" ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}已关闭${NC}")"
    echo -e "WebServer功能开关：$([[ $WEBSERVER_ENABLED == "yes" ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}已关闭${NC}")"
    echo -e "API监听地址：${BLUE}$WEBSERVER_ADDRESS${NC}"
    echo -e "API监听端口：${BLUE}$WEBSERVER_PORT${NC}"
    echo -e "允许访问的IP段：${BLUE}$WEBSERVER_ALLOW_FROM${NC}"
    
    if [[ -n $API_KEY ]]; then
        echo -e "API访问密钥：${GREEN}$API_KEY${NC}"
    else
        echo -e "API访问密钥：${RED}未配置${NC}"
    fi

    # 4. 输出API访问信息
    log_title "API 访问信息"
    # 提取实际端口号（去掉默认值备注）
    ACTUAL_PORT=$(echo "$WEBSERVER_PORT" | awk '{print $1}')
    ACTUAL_ADDRESS=$(echo "$WEBSERVER_ADDRESS" | awk '{print $1}')
    SERVER_IPS=$(hostname -I | xargs 2>/dev/null || echo "无法获取")

    echo -e "服务器所有网卡IP：${BLUE}$SERVER_IPS${NC}"
    echo -e "本地环回访问地址：http://127.0.0.1:$ACTUAL_PORT"
    if [[ $ACTUAL_ADDRESS == "0.0.0.0" ]]; then
        echo -e "全网卡监听，可通过服务器任意IP访问：http://服务器IP:$ACTUAL_PORT"
    else
        echo -e "指定地址监听，仅可通过监听地址访问：http://$ACTUAL_ADDRESS:$ACTUAL_PORT"
    fi

    # 5. 防火墙检查
    log_title "防火墙端口检查"
    check_firewall_port "$ACTUAL_PORT"

    # 6. 异常情况提示与引导
    local API_NORMAL=1
    if [[ $API_ENABLED != "yes" ]]; then
        log_warn "检测到API功能未开启，无法提供API服务"
        API_NORMAL=0
    fi
    if [[ $WEBSERVER_ENABLED != "yes" ]]; then
        log_warn "检测到WebServer功能未开启，API依赖WebServer，无法提供服务"
        API_NORMAL=0
    fi
    if [[ -z $API_KEY ]]; then
        log_warn "检测到未配置API密钥，API功能无法正常使用"
        API_NORMAL=0
    fi

    # 提供一键配置入口
    if [[ $API_NORMAL -eq 0 ]]; then
        echo ""
        log_warn "检测到API配置不完整/未开启，可使用一键配置功能自动完成API部署"
        read -p "是否执行一键配置PowerDNS API？(yes/no，默认no)：" AUTO_CONFIG
        AUTO_CONFIG=${AUTO_CONFIG:-no}
        if [[ $AUTO_CONFIG == "yes" ]]; then
            auto_config_api
        fi
    else
        log_info "✅ PowerDNS API配置完整，可正常使用"
    fi

    echo ""
    log_info "API信息获取完成"
}

# 菜单展示
show_menu() {
    clear
    echo "====================================="
    echo "  PowerDNS API 信息管理脚本"
    echo "  全系统兼容 | 一键获取 | 自动配置"
    echo "====================================="
    echo " 1. 一键获取PowerDNS API完整信息"
    echo " 2. 一键配置并开启PowerDNS API"
    echo " 0. 退出脚本"
    echo "====================================="
    read -p "请输入要执行的操作编号：" MENU_CHOICE
}

# 主程序入口
main() {
    detect_os
    while true; do
        show_menu
        case $MENU_CHOICE in
            1) get_pdns_api_info ;;
            2) auto_config_api ;;
            0) log_info "脚本已退出，感谢使用"; exit 0 ;;
            *) log_error "无效的操作编号，请重新输入" ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..."
    done
}

# 执行主程序
main
