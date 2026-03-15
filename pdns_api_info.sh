#!/bin/bash
set -o nounset
set -o pipefail

# 终端颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 安全默认配置（核心优化：默认强制本地安全地址）
DEFAULT_WEBSERVER_ADDRESS="127.0.0.1"
DEFAULT_WEBSERVER_PORT="8081"
custom_webserver_address="$DEFAULT_WEBSERVER_ADDRESS"
custom_webserver_port="$DEFAULT_WEBSERVER_PORT"

# 帮助信息
show_help() {
    cat << EOF
用法: $0 [选项] [配置文件路径]
获取/生成PowerDNS API Key，新增安全地址自定义、配置自动修复、一键加固功能，默认使用127.0.0.1安全本地地址

选项:
  -h, --help          显示此帮助信息并退出
  -a, --address <ip>  自定义webserver监听地址，默认127.0.0.1（安全推荐，仅本地访问）
  -p, --port <端口>   自定义webserver监听端口，默认8081

示例:
  $0                              自动查找配置，使用默认127.0.0.1安全地址
  $0 -a 192.168.1.100            自定义内网监听地址
  $0 -a 127.0.0.1 -p 8082        自定义本地地址和端口
  $0 /etc/pdns/pdns.conf          手动指定配置文件路径
EOF
}

# 权限检查
check_permission() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}警告: 当前非root用户运行，可能无法读取/修改PowerDNS配置文件，建议使用sudo执行${NC}" >&2
    fi
}

# 校验IPv4地址合法性
validate_ip() {
    local ip="$1"
    # 标准IPv4格式校验，避免无效地址配置
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS=.
        local -a octets=($ip)
        for oct in "${octets[@]}"; do
            if [[ $oct -lt 0 || $oct -gt 255 ]]; then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# 校验端口合法性
validate_port() {
    local port="$1"
    if [[ "$port" =~ ^[0-9]+$ && $port -ge 1 && $port -le 65535 ]]; then
        return 0
    else
        return 1
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

# 配置文件备份函数
backup_conf() {
    local conf_file="$1"
    local backup_file="${conf_file}.bak.$(date +%Y%m%d%H%M%S)"
    if cp -a "$conf_file" "$backup_file"; then
        echo -e "${GREEN}已自动备份原配置文件: $backup_file${NC}"
        return 0
    else
        echo -e "${RED}错误: 配置文件备份失败，为避免数据风险，终止修改操作${NC}" >&2
        return 1
    fi
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
            -a|--address)
                if [[ -z "$2" ]]; then
                    echo -e "${RED}错误: --address 选项必须指定IP地址参数${NC}" >&2
                    show_help
                    exit 1
                fi
                custom_webserver_address="$2"
                shift 2
                ;;
            -p|--port)
                if [[ -z "$2" ]]; then
                    echo -e "${RED}错误: --port 选项必须指定端口参数${NC}" >&2
                    show_help
                    exit 1
                fi
                custom_webserver_port="$2"
                shift 2
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

    # 前置校验
    check_permission

    # 校验IP地址合法性
    if ! validate_ip "$custom_webserver_address"; then
        echo -e "${RED}错误: 指定的监听地址不是合法的IPv4地址: $custom_webserver_address${NC}" >&2
        echo -e "合法示例: 127.0.0.1、192.168.1.100" >&2
        exit 1
    fi

    # 校验端口合法性
    if ! validate_port "$custom_webserver_port"; then
        echo -e "${RED}错误: 指定的端口不是合法的端口号（1-65535）: $custom_webserver_port${NC}" >&2
        exit 1
    fi

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

    # 补全默认值
    webserver_address=${webserver_address:-"未配置"}
    webserver_port=${webserver_port:-"$DEFAULT_WEBSERVER_PORT"}
    local api_base_url="http://${custom_webserver_address}:${custom_webserver_port}/api/v1"

    # 场景1：未配置API Key，生成安全配置
    if [[ -z "$api_key" ]]; then
        echo -e "${RED}错误: 未找到有效的 API Key 配置${NC}" >&2
        echo -e "配置文件中未配置 api-key=xxx 或配置项被注释\n" >&2
        
        # 生成高安全随机API Key
        local new_key=$(generate_api_key)
        if [[ -z "$new_key" ]]; then
            echo -e "${RED}错误: 生成随机API Key失败，请检查openssl是否安装${NC}" >&2
            exit 1
        fi

        # 输出安全配置模板
        echo -e "✅ 已为您生成高安全API配置（默认使用您指定的安全地址）："
        echo -e "-----------------------------------------"
        echo -e "webserver=yes"
        echo -e "api=yes"
        echo -e "api-key=$new_key"
        echo -e "webserver-address=$custom_webserver_address"
        echo -e "webserver-port=$custom_webserver_port"
        echo -e "-----------------------------------------\n"

        # 自动写入配置交互
        read -p "是否自动将上述安全配置写入配置文件（自动备份原文件）？(y/N): " auto_write
        if [[ "$auto_write" =~ ^[Yy]$ ]]; then
            # 先备份
            backup_conf "$conf_file" || exit 1

            # 清理已有的相关配置（含注释行，避免冲突）
            sed -i.bak -E '/^[# ]*(webserver|api|api-key|webserver-address|webserver-port)=/d' "$conf_file"
            
            # 写入新的安全配置
            cat >> "$conf_file" << EOF
# PowerDNS API 安全配置（脚本自动生成，$(date +%Y-%m-%d %H:%M:%S)）
webserver=yes
api=yes
api-key=$new_key
webserver-address=$custom_webserver_address
webserver-port=$custom_webserver_port
EOF

            if [[ $? -eq 0 ]]; then
                echo -e "\n${GREEN}✅ 安全配置已成功写入 $conf_file${NC}"
                echo -e "🔑 生成的API Key: ${GREEN}$new_key${NC}"
                echo -e "🌐 API 基础地址: $api_base_url"
                echo -e "\n⚠️  配置已更新，请重启PowerDNS服务生效："
                echo -e "  systemctl restart pdns 或 systemctl restart powerdns"
                exit 0
            else
                echo -e "${RED}错误: 写入配置文件失败，请手动检查${NC}" >&2
                exit 1
            fi
        fi
        exit 1
    fi

    # 场景2：已存在API Key，输出配置信息+合规性检查
    echo -e "============================================="
    echo -e "${GREEN}✅ PowerDNS API 配置信息获取成功${NC}"
    echo -e "============================================="
    echo -e "🔑 API Key:         ${GREEN}${api_key}${NC}"
    echo -e "🌐 API 基础地址:    http://${webserver_address}:${webserver_port}/api/v1"
    echo -e "📡 当前监听地址:    ${webserver_address}"
    echo -e "🔌 当前监听端口:    ${webserver_port}"
    echo -e "⚙️  API 功能状态:    $( [[ "$api_enabled" == "yes" ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}未开启${NC}" )"
    echo -e "🌐 WebServer 状态:  $( [[ "$webserver_enabled" == "yes" ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${RED}未开启${NC}" )"
    echo -e "============================================="

    # 配置合规性与安全风险检查
    local has_error=0
    local has_warning=0

    # 检查WebServer依赖
    if [[ "$webserver_enabled" != "yes" ]]; then
        echo -e "\n${RED}❌ 严重问题: WebServer 未开启${NC}"
        echo -e "PowerDNS API 强依赖WebServer服务，必须配置 webserver=yes 才能正常使用API"
        has_error=1
    fi

    # 检查API总开关
    if [[ "$api_enabled" != "yes" ]]; then
        echo -e "\n${RED}❌ 严重问题: API 功能未开启${NC}"
        echo -e "即使配置了API Key，也无法调用任何API接口，必须配置 api=yes"
        has_error=1
    fi

    # 高风险安全检查：全地址监听
    if [[ "$webserver_address" == "0.0.0.0" ]]; then
        echo -e "\n${RED}⚠️  高风险安全警告: WebServer 绑定到了 0.0.0.0（全地址监听）${NC}"
        echo -e "这会将PowerDNS API接口完全暴露到所有网络，存在严重的未授权访问、数据泄露、DNS篡改风险"
        echo -e "安全推荐：仅绑定本地回环地址 $custom_webserver_address 或指定的内网信任地址"
        has_warning=1

        # 一键修复安全地址
        read -p "是否自动将监听地址修改为安全地址 $custom_webserver_address？(y/N): " fix_address
        if [[ "$fix_address" =~ ^[Yy]$ ]]; then
            backup_conf "$conf_file" || exit 1
            # 修改配置，不存在则新增
            if grep -q "^webserver-address=" "$conf_file"; then
                sed -i.bak -E "s/^webserver-address=.*/webserver-address=$custom_webserver_address/" "$conf_file"
            else
                echo "webserver-address=$custom_webserver_address" >> "$conf_file"
            fi

            if [[ $? -eq 0 ]]; then
                echo -e "${GREEN}✅ 监听地址已成功修改为 $custom_webserver_address${NC}"
                echo -e "请重启PowerDNS服务生效：systemctl restart pdns 或 systemctl restart powerdns"
            else
                echo -e "${RED}错误: 修改配置文件失败，请手动检查${NC}" >&2
            fi
        fi
    # 非内网/非本地地址提醒
    elif [[ "$webserver_address" != "127.0.0.1" && ! "$webserver_address" =~ ^192\.168\. && ! "$webserver_address" =~ ^10\. && ! "$webserver_address" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]]; then
        echo -e "\n${YELLOW}⚠️  安全提醒: WebServer 绑定到了公网地址 $webserver_address${NC}"
        echo -e "请务必通过防火墙严格限制访问来源IP，仅放行信任地址，避免API接口暴露到公网"
        has_warning=1
    fi

    # 异常状态处理
    if [[ $has_error -eq 1 ]]; then
        echo -e "\n${RED}❌ 存在核心配置错误，API将无法正常使用，请修复上述问题${NC}"
        exit 1
    fi

    if [[ $has_warning -eq 1 ]]; then
        echo -e "\n${YELLOW}⚠️  存在安全风险或配置警告，请留意上述提示项${NC}"
    fi

    # 连通性测试提示
    echo -e "\n📌 API连通性测试命令（直接复制执行）："
    echo -e "curl -H \"X-API-Key: ${api_key}\" http://${webserver_address}:${webserver_port}/api/v1/servers/localhost"
}

# 执行主逻辑
main "$@"
