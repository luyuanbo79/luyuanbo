#!/bin/bash
set -o nounset
set -o pipefail

# 终端颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 帮助信息
show_help() {
    cat << EOF
用法: $0 [选项] [配置文件路径]
获取PowerDNS DNS服务器的API Key及完整API配置信息，支持配置校验与自动生成密钥

选项:
  -h, --help          显示此帮助信息并退出

示例:
  $0                  自动查找系统默认路径的pdns.conf
  $0 /etc/pdns/pdns.conf  手动指定pdns.conf配置文件路径
EOF
}

# 权限检查
check_permission() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}警告: 当前非root用户运行，可能无法读取PowerDNS配置文件，建议使用sudo执行${NC}" >&2
    fi
}

# 自动查找pdns.conf配置文件
find_pdns_conf() {
    local conf_paths=(
        "/etc/powerdns/pdns.conf"
        "/etc/pdns/pdns.conf"
        "/usr/local/etc/pdns/pdns.conf"
        "/opt/powerdns/etc/pdns.conf"
    )
    
    for path in "${conf_paths[@]}"; do
        if [[ -f "$path" ]]; then
            echo "$path"
            return 0
        fi
    done
    
    return 1
}

# 提取配置项（自动过滤注释行、去除前后空格）
get_config_value() {
    local conf_file="$1"
    local key="$2"
    grep -E "^${key}=" "$conf_file" 2>/dev/null | cut -d '=' -f 2- | xargs
}

# 生成32位安全随机API Key
generate_api_key() {
    openssl rand -hex 16 2>/dev/null
}

# 主逻辑
main() {
    # 处理入参
    local conf_file=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                if [[ -z "$conf_file" ]]; then
                    conf_file="$1"
                else
                    echo -e "${RED}错误: 多余的参数: $1${NC}" >&2
                    show_help
                    exit 1
                fi
                shift
                ;;
        esac
    done

    # 前置权限检查
    check_permission

    # 确定配置文件路径
    if [[ -n "$conf_file" ]]; then
        if [[ ! -f "$conf_file" ]]; then
            echo -e "${RED}错误: 指定的配置文件不存在: $conf_file${NC}" >&2
            exit 1
        fi
    else
        conf_file=$(find_pdns_conf)
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}错误: 未找到PowerDNS主配置文件pdns.conf${NC}" >&2
            echo -e "常见配置路径:" >&2
            echo -e "  - Debian/Ubuntu 系列: /etc/powerdns/pdns.conf" >&2
            echo -e "  - CentOS/RHEL 系列: /etc/pdns/pdns.conf" >&2
            echo -e "  - 自定义编译安装: /usr/local/etc/pdns/pdns.conf" >&2
            echo -e "请手动指定路径执行: $0 /path/to/pdns.conf" >&2
            exit 1
        fi
    fi

    # 检查文件可读性
    if [[ ! -r "$conf_file" ]]; then
        echo -e "${RED}错误: 无法读取配置文件 $conf_file，权限不足${NC}" >&2
        echo -e "请使用root用户或sudo执行此脚本" >&2
        exit 1
    fi

    echo -e "${GREEN}已定位PowerDNS配置文件: $conf_file${NC}\n"

    # 提取核心API相关配置
    local webserver_enabled=$(get_config_value "$conf_file" "webserver" | tr '[:upper:]' '[:lower:]')
    local api_enabled=$(get_config_value "$conf_file" "api" | tr '[:upper:]' '[:lower:]')
    local api_key=$(get_config_value "$conf_file" "api-key")
    local webserver_address=$(get_config_value "$conf_file" "webserver-address")
    local webserver_port=$(get_config_value "$conf_file" "webserver-port")

    # 配置合规性检查
    local has_warning=0

    # 检查WebServer（API依赖WebServer）
    if [[ "$webserver_enabled" != "yes" ]]; then
        echo -e "${YELLOW}警告: WebServer 未开启 (webserver=yes 未配置或被注释)${NC}" >&2
        echo -e "PowerDNS API 依赖WebServer服务，需开启后才能正常调用API\n" >&2
        has_warning=1
    fi

    # 检查API总开关
    if [[ "$api_enabled" != "yes" ]]; then
        echo -e "${YELLOW}警告: API 功能未开启 (api=yes 未配置或被注释)${NC}" >&2
        echo -e "即使配置了API Key，也无法调用API接口\n" >&2
        has_warning=1
    fi

    # 检查API Key配置
    if [[ -z "$api_key" ]]; then
        echo -e "${RED}错误: 未找到有效的 API Key 配置${NC}" >&2
        echo -e "配置文件中未配置 api-key=xxx 或配置项被注释\n" >&2
        
        # 自动生成安全密钥
        local new_key=$(generate_api_key)
        if [[ -n "$new_key" ]]; then
            echo -e "已为您生成高安全随机API Key: ${GREEN}$new_key${NC}"
            echo -e "请将以下完整配置添加到 $conf_file 末尾："
            echo -e "-----------------------------------------"
            echo -e "webserver=yes"
            echo -e "api=yes"
            echo -e "api-key=$new_key"
            echo -e "webserver-address=127.0.0.1"
            echo -e "webserver-port=8081"
            echo -e "-----------------------------------------"
            echo -e "\n配置完成后，重启PowerDNS服务生效："
            echo -e "  systemctl restart pdns 或 systemctl restart powerdns"
        fi
        exit 1
    fi

    # 补全默认值
    webserver_address=${webserver_address:-"127.0.0.1"}
    webserver_port=${webserver_port:-"8081"}
    local api_base_url="http://${webserver_address}:${webserver_port}/api/v1"

    # 输出最终结果
    echo -e "============================================="
    echo -e "${GREEN}✅ PowerDNS API 配置信息获取成功${NC}"
    echo -e "============================================="
    echo -e "🔑 API Key:         ${GREEN}${api_key}${NC}"
    echo -e "🌐 API 基础地址:    ${api_base_url}"
    echo -e "📡 监听地址:        ${webserver_address}"
    echo -e "🔌 监听端口:        ${webserver_port}"
    echo -e "⚙️  API 功能状态:    $( [[ "$api_enabled" == "yes" ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}未开启${NC}" )"
    echo -e "🌐 WebServer 状态:  $( [[ "$webserver_enabled" == "yes" ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}未开启${NC}" )"
    echo -e "============================================="

    # 安全提示
    if [[ "$webserver_address" == "0.0.0.0" ]]; then
        echo -e "\n${YELLOW}⚠️  安全警告: WebServer 绑定到了 0.0.0.0，存在公网暴露风险${NC}"
        echo -e "建议仅绑定内网地址或127.0.0.1，并通过防火墙严格限制访问来源IP"
    fi

    if [[ $has_warning -eq 1 ]]; then
        echo -e "\n${YELLOW}⚠️  存在配置警告，API可能无法正常使用，请检查上述提示项${NC}"
        exit 2
    fi

    # 测试命令提示
    echo -e "\n📌 API连通性测试命令（替换为你的API Key）："
    echo -e "curl -H \"X-API-Key: ${api_key}\" ${api_base_url}/servers/localhost"
}

# 执行主逻辑
main "$@"
