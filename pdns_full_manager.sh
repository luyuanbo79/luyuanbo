#!/bin/bash
set -o pipefail

# ===================== 通用基础函数 =====================
# 颜色输出
info() {
    echo -e "\033[32m[信息] $1\033[0m"
}
warn() {
    echo -e "\033[33m[警告] $1\033[0m"
}
error() {
    echo -e "\033[31m[错误] $1\033[0m"
}
success() {
    echo -e "\033[32m[成功] $1\033[0m"
}

# 全局变量
BACKUP_SUFFIX=$(date +%Y%m%d%H%M%S)
OS=""
VERSION_ID=""
PM=""
PM_UPDATE=""
PM_INSTALL=""
PM_REMOVE=""
PM_AUTOREMOVE=""
# PowerDNS 相关路径
PDNS_CONF=""
PDNS_CONF_DIR=""
# PowerAdmin 相关路径
POWERADMIN_WEB_ROOT="/var/www/poweradmin"
NGINX_CONF_PATH=""
PHP_FPM_SERVICE=""

# 系统发行版检测（全系统兼容）
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    else
        error "无法检测系统发行版，脚本仅支持 Debian/Ubuntu 和 RHEL/CentOS/Rocky/AlmaLinux 系统"
        exit 1
    fi

    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        PM="apt"
        PM_UPDATE="apt update -y"
        PM_INSTALL="apt install -y"
        PM_REMOVE="apt remove -y --purge"
        PM_AUTOREMOVE="apt autoremove -y --purge"
        PDNS_CONF="/etc/powerdns/pdns.conf"
        PDNS_CONF_DIR="/etc/powerdns/pdns.d"
        NGINX_CONF_PATH="/etc/nginx/sites-available/poweradmin.conf"
        NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/poweradmin.conf"
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        PM="dnf"
        if ! command -v dnf &> /dev/null; then
            PM="yum"
        fi
        PM_UPDATE="$PM makecache -y"
        PM_INSTALL="$PM install -y"
        PM_REMOVE="$PM remove -y"
        PM_AUTOREMOVE="$PM autoremove -y"
        PDNS_CONF="/etc/pdns/pdns.conf"
        PDNS_CONF_DIR="/etc/pdns/pdns.d"
        NGINX_CONF_PATH="/etc/nginx/conf.d/poweradmin.conf"
    else
        error "不支持的系统发行版 $OS，脚本仅支持 Debian/Ubuntu 和 RHEL/CentOS/Rocky/AlmaLinux 系统"
        exit 1
    fi
}

# 生成随机字符串
generate_random() {
    local length=${1:-16}
    tr -dc A-Za-z0-9 < /dev/urandom | head -c $length
}

# 端口占用检查
check_port() {
    local port=$1
    local proto=${2:-tcp}
    if ss -${proto}lnp | grep -q ":$port\b"; then
        return 0
    else
        return 1
    fi
}

# 修复 systemd-resolved 53端口占用（仅PowerDNS安装时调用）
fix_systemd_resolved() {
    if check_port 53 udp && ss -ulnp | grep :53 | grep -q systemd-resolved; then
        warn "检测到 systemd-resolved 占用53端口，正在释放端口..."
        sed -i.bak."$BACKUP_SUFFIX" -E 's/#?DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
        systemctl daemon-reload
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        info "已释放53端口，原配置已备份"
    fi
}

# MySQL 登录权限检测
check_mysql_login() {
    local host=$1
    local port=$2
    local user=$3
    local pass=$4
    local db=${5:-mysql}
    if mysql -h "$host" -P "$port" -u "$user" -p"$pass" -e "USE $db;" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

# 服务是否存在检测
service_exists() {
    local service_name=$1
    if systemctl list-unit-files | grep -q "^$service_name.service"; then
        return 0
    else
        return 1
    fi
}

# ===================== PowerDNS 专属功能函数（完全独立） =====================
# 1. PowerDNS 主节点安装（独立安装，不碰PowerAdmin相关组件）
install_pdns_master() {
    info "开始独立安装 PowerDNS 主节点（含数据库、API，不包含PowerAdmin）"
    detect_os
    fix_systemd_resolved

    # 前置检查
    if service_exists pdns; then
        warn "检测到 PowerDNS 已安装，重复安装将覆盖原有配置，配置文件将自动备份"
        read -p "是否继续安装? [y/N]: " CONFIRM
        CONFIRM=${CONFIRM,,}
        if [ "$CONFIRM" != "y" ]; then
            info "已取消安装"
            return 0
        fi
    fi

    # 更新系统包
    info "正在更新系统包..."
    $PM_UPDATE
    if [ $? -ne 0 ]; then
        warn "系统包更新失败，不影响核心安装，建议手动检查源配置"
    fi

    # 安装基础依赖
    info "正在安装基础依赖..."
    $PM_INSTALL curl wget gnupg2 ca-certificates
    if [ $? -ne 0 ]; then
        error "基础依赖安装失败，无法继续安装"
        return 1
    fi

    # 安装/处理 MariaDB 数据库
    local DB_INSTALLED=0
    if service_exists mariadb; then
        DB_INSTALLED=1
        warn "检测到 MariaDB 已安装，将使用现有数据库"
        # 验证root权限
        while true; do
            read -s -p "请输入 MariaDB root 密码: " DB_ROOT_PASS
            echo ""
            if check_mysql_login "127.0.0.1" "3306" "root" "$DB_ROOT_PASS"; then
                success "数据库root权限验证通过"
                break
            else
                error "root密码错误，请重新输入"
            fi
        done
    else
        info "未检测到 MariaDB，正在安装数据库..."
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
            $PM_INSTALL mariadb-server mariadb-client
        else
            $PM_INSTALL mariadb-server mariadb
        fi
        if [ $? -ne 0 ]; then
            error "MariaDB 安装失败"
            return 1
        fi
        # 启动数据库
        systemctl daemon-reload
        systemctl start mariadb
        systemctl enable mariadb
        if ! systemctl is-active --quiet mariadb; then
            error "MariaDB 服务启动失败"
            return 1
        fi
        # 初始化root密码
        DB_ROOT_PASS=$(generate_random 16)
        mysqladmin -u root password "$DB_ROOT_PASS"
        if ! check_mysql_login "127.0.0.1" "3306" "root" "$DB_ROOT_PASS"; then
            error "MariaDB root密码初始化失败"
            return 1
        fi
        success "MariaDB 安装并初始化完成"
    fi

    # 添加 PowerDNS 官方源
    info "正在添加 PowerDNS 官方源..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        curl -fsSL https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor > /usr/share/keyrings/powerdns-archive-keyring.gpg
        if [ "$OS" = "debian" ]; then
            DEB_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
            echo "deb [signed-by=/usr/share/keyrings/powerdns-archive-keyring.gpg] http://repo.powerdns.com/debian $DEB_CODENAME-auth-49 main" > /etc/apt/sources.list.d/powerdns-auth.list
        elif [ "$OS" = "ubuntu" ]; then
            UBUNTU_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
            echo "deb [signed-by=/usr/share/keyrings/powerdns-archive-keyring.gpg] http://repo.powerdns.com/ubuntu $UBUNTU_CODENAME-auth-49 main" > /etc/apt/sources.list.d/powerdns-auth.list
        fi
        apt update -y
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        cat > /etc/yum.repos.d/powerdns-auth.repo << EOF
[powerdns-auth]
name=PowerDNS Authoritative Server
baseurl=https://repo.powerdns.com/rhel/\$releasever/auth-49/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://repo.powerdns.com/FD380FBB-pub.asc
EOF
        $PM_UPDATE
    fi
    if [ $? -ne 0 ]; then
        error "PowerDNS 官方源添加失败"
        return 1
    fi
    success "PowerDNS 官方源添加成功"

    # 安装 PowerDNS
    info "正在安装 PowerDNS 服务..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        $PM_INSTALL pdns-server pdns-backend-mysql
    else
        $PM_INSTALL pdns pdns-backend-mysql
    fi
    if [ $? -ne 0 ]; then
        error "PowerDNS 安装失败"
        return 1
    fi
    success "PowerDNS 安装成功"

    # 配置变量定义
    PDNS_DB_NAME="powerdns"
    PDNS_DB_USER="powerdns"
    PDNS_DB_PASS=$(generate_random 16)
    PDNS_API_KEY=$(generate_random 32)
    PDNS_API_PORT=8081
    PDNS_WEB_ALLOW_FROM="0.0.0.0/0"

    # 数据库初始化（全容错，解决已存在报错）
    info "正在初始化 PowerDNS 数据库..."
    mysql -u root -p"$DB_ROOT_PASS" << EOF
-- 安全初始化，无报错
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
-- 兼容已存在的数据库/用户，不报错
CREATE DATABASE IF NOT EXISTS $PDNS_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$PDNS_DB_USER'@'localhost' IDENTIFIED BY '$PDNS_DB_PASS';
GRANT ALL PRIVILEGES ON $PDNS_DB_NAME.* TO '$PDNS_DB_USER'@'localhost';
CREATE USER IF NOT EXISTS '$PDNS_DB_USER'@'%' IDENTIFIED BY '$PDNS_DB_PASS';
GRANT ALL PRIVILEGES ON $PDNS_DB_NAME.* TO '$PDNS_DB_USER'@'%';
FLUSH PRIVILEGES;
EOF
    if [ $? -ne 0 ]; then
        error "数据库初始化失败，请检查MariaDB权限"
        return 1
    fi
    success "数据库初始化完成"

    # 导入PowerDNS表结构（容错，已存在则跳过）
    info "正在检查并导入 PowerDNS 表结构..."
    TABLE_EXIST=$(mysql -u "$PDNS_DB_USER" -p"$PDNS_DB_PASS" "$PDNS_DB_NAME" -e "SHOW TABLES LIKE 'domains';" 2>/dev/null | wc -l)
    if [ "$TABLE_EXIST" -eq 0 ]; then
        info "未检测到表结构，正在导入..."
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
            SCHEMA_FILE="/usr/share/doc/pdns-backend-mysql/schema.mysql.sql.gz"
            if [ ! -f "$SCHEMA_FILE" ]; then
                error "表结构文件不存在：$SCHEMA_FILE"
                return 1
            fi
            zcat "$SCHEMA_FILE" | mysql -u "$PDNS_DB_USER" -p"$PDNS_DB_PASS" "$PDNS_DB_NAME"
        else
            SCHEMA_FILE="/usr/share/doc/pdns/schema.mysql.sql"
            if [ ! -f "$SCHEMA_FILE" ]; then
                error "表结构文件不存在：$SCHEMA_FILE"
                return 1
            fi
            mysql -u "$PDNS_DB_USER" -p"$PDNS_DB_PASS" "$PDNS_DB_NAME" < "$SCHEMA_FILE"
        fi
        if [ $? -ne 0 ]; then
            error "表结构导入失败"
            return 1
        fi
        success "PowerDNS 表结构导入完成"
    else
        warn "检测到 PowerDNS 表结构已存在，跳过导入步骤"
    fi

    # 配置PowerDNS（自动备份原有配置）
    info "正在配置 PowerDNS..."
    if [ -f "$PDNS_CONF" ]; then
        cp "$PDNS_CONF" "$PDNS_CONF.bak.$BACKUP_SUFFIX"
        info "原有配置文件已备份至 $PDNS_CONF.bak.$BACKUP_SUFFIX"
    fi
    cat > "$PDNS_CONF" << EOF
# PowerDNS 主节点配置文件（自动生成）
setuid=pdns
setgid=pdns
local-address=0.0.0.0
local-port=53
master=yes
slave=no
disable-axfr=no
allow-axfr-ips=0.0.0.0/0
daemon=yes
guardian=yes
default-ttl=3600
max-ttl=604800
min-ttl=300

# MySQL 后端配置
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=$PDNS_DB_NAME
gmysql-user=$PDNS_DB_USER
gmysql-password=$PDNS_DB_PASS
gmysql-dnssec=yes

# API 配置
api=yes
api-key=$PDNS_API_KEY
webserver=yes
webserver-address=0.0.0.0
webserver-port=$PDNS_API_PORT
webserver-allow-from=$PDNS_WEB_ALLOW_FROM
webserver-password=$PDNS_API_KEY

# 日志配置
loglevel=3
logging-facility=0
log-dns-details=yes
log-dns-queries=yes
EOF
    # 删除默认bind后端冲突配置
    if [ -f "$PDNS_CONF_DIR/bind.conf" ]; then
        rm -f "$PDNS_CONF_DIR/bind.conf"
        info "已删除默认bind后端配置，避免启动冲突"
    fi
    success "PowerDNS 配置完成"

    # 启动PowerDNS服务
    info "正在启动 PowerDNS 服务..."
    systemctl daemon-reload
    systemctl restart pdns
    if ! systemctl is-active --quiet pdns; then
        error "PowerDNS 服务启动失败，请查看日志：journalctl -xeu pdns"
        return 1
    fi
    systemctl enable pdns
    success "PowerDNS 服务启动成功，已设置开机自启"

    # 防火墙配置
    info "正在配置防火墙规则..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
        if ufw status | grep -q "active"; then
            ufw allow 53/tcp 2>/dev/null
            ufw allow 53/udp 2>/dev/null
            ufw allow $PDNS_API_PORT/tcp 2>/dev/null
            ufw reload 2>/dev/null
            success "UFW 防火墙规则配置完成"
        else
            warn "UFW 防火墙未启用，跳过规则配置"
        fi
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=53/tcp 2>/dev/null
            firewall-cmd --permanent --add-port=53/udp 2>/dev/null
            firewall-cmd --permanent --add-port=$PDNS_API_PORT/tcp 2>/dev/null
            firewall-cmd --reload 2>/dev/null
            success "Firewalld 防火墙规则配置完成"
        else
            warn "Firewalld 防火墙未启用，跳过规则配置"
        fi
    else
        warn "未检测到可用防火墙工具，跳过配置"
    fi

    # 获取服务器IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="本机IP"
    fi

    # 输出安装结果
    echo ""
    success "================================= PowerDNS 主节点安装完成 =================================="
    info "【数据库信息】（安装PowerAdmin时需要用到）"
    if [ $DB_INSTALLED -eq 0 ]; then
        info "MariaDB root 密码: $DB_ROOT_PASS"
    fi
    info "PowerDNS 数据库地址: 127.0.0.1"
    info "PowerDNS 数据库端口: 3306"
    info "PowerDNS 数据库名: $PDNS_DB_NAME"
    info "PowerDNS 数据库用户名: $PDNS_DB_USER"
    info "PowerDNS 数据库密码: $PDNS_DB_PASS"
    echo ""
    info "【PowerDNS API 信息】（安装PowerAdmin时需要用到）"
    info "API 地址: http://$SERVER_IP:$PDNS_API_PORT"
    info "API Key: $PDNS_API_KEY"
    echo ""
    info "【服务信息】"
    info "DNS 服务端口: 53(TCP/UDP)"
    info "服务已设置开机自启"
    echo ""
    warn "【重要提示】请妥善保存以上信息，后续安装PowerAdmin或配置从节点需要使用"
    success "============================================================================================"
    echo ""
}

# 2. PowerDNS 从节点安装（独立多节点部署）
install_pdns_slave() {
    info "开始独立安装 PowerDNS 从节点（多节点扩展，不包含PowerAdmin）"
    detect_os
    fix_systemd_resolved

    # 前置检查
    if service_exists pdns; then
        warn "检测到 PowerDNS 已安装，重复安装将覆盖原有配置，配置文件将自动备份"
        read -p "是否继续安装? [y/N]: " CONFIRM
        CONFIRM=${CONFIRM,,}
        if [ "$CONFIRM" != "y" ]; then
            info "已取消安装"
            return 0
        fi
    fi

    # 更新系统包
    info "正在更新系统包..."
    $PM_UPDATE
    if [ $? -ne 0 ]; then
        warn "系统包更新失败，不影响核心安装"
    fi

    # 安装基础依赖
    info "正在安装基础依赖..."
    $PM_INSTALL curl wget gnupg2 ca-certificates
    if [ $? -ne 0 ]; then
        error "基础依赖安装失败"
        return 1
    fi

    # 添加PowerDNS官方源
    info "正在添加 PowerDNS 官方源..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        curl -fsSL https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor > /usr/share/keyrings/powerdns-archive-keyring.gpg
        if [ "$OS" = "debian" ]; then
            DEB_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
            echo "deb [signed-by=/usr/share/keyrings/powerdns-archive-keyring.gpg] http://repo.powerdns.com/debian $DEB_CODENAME-auth-49 main" > /etc/apt/sources.list.d/powerdns-auth.list
        elif [ "$OS" = "ubuntu" ]; then
            UBUNTU_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
            echo "deb [signed-by=/usr/share/keyrings/powerdns-archive-keyring.gpg] http://repo.powerdns.com/ubuntu $UBUNTU_CODENAME-auth-49 main" > /etc/apt/sources.list.d/powerdns-auth.list
        fi
        apt update -y
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        cat > /etc/yum.repos.d/powerdns-auth.repo << EOF
[powerdns-auth]
name=PowerDNS Authoritative Server
baseurl=https://repo.powerdns.com/rhel/\$releasever/auth-49/\$basearch
enabled=1
gpgcheck=1
gpgkey=https://repo.powerdns.com/FD380FBB-pub.asc
EOF
        $PM_UPDATE
    fi
    if [ $? -ne 0 ]; then
        error "PowerDNS 官方源添加失败"
        return 1
    fi
    success "PowerDNS 官方源添加成功"

    # 安装PowerDNS
    info "正在安装 PowerDNS 服务..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        $PM_INSTALL pdns-server pdns-backend-mysql
    else
        $PM_INSTALL pdns pdns-backend-mysql
    fi
    if [ $? -ne 0 ]; then
        error "PowerDNS 安装失败"
        return 1
    fi
    success "PowerDNS 安装成功"

    # 获取主节点数据库信息
    echo -e "\033[33m请输入主节点 PowerDNS 数据库配置信息：\033[0m"
    read -p "主节点数据库IP地址: " MASTER_DB_HOST
    if [ -z "$MASTER_DB_HOST" ]; then
        error "数据库IP地址不能为空"
        return 1
    fi
    read -p "数据库端口 [默认3306]: " MASTER_DB_PORT
    MASTER_DB_PORT=${MASTER_DB_PORT:-3306}
    read -p "PowerDNS数据库名 [默认powerdns]: " MASTER_DB_NAME
    MASTER_DB_NAME=${MASTER_DB_NAME:-powerdns}
    read -p "PowerDNS数据库用户名 [默认powerdns]: " MASTER_DB_USER
    MASTER_DB_USER=${MASTER_DB_USER:-powerdns}
    read -s -p "PowerDNS数据库密码: " MASTER_DB_PASS
    echo ""
    if [ -z "$MASTER_DB_PASS" ]; then
        error "数据库密码不能为空"
        return 1
    fi

    # 测试数据库连接
    info "正在测试数据库连接..."
    if ! command -v mysql &> /dev/null; then
        info "正在安装mysql客户端用于测试连接..."
        $PM_INSTALL mariadb-client
    fi
    if ! check_mysql_login "$MASTER_DB_HOST" "$MASTER_DB_PORT" "$MASTER_DB_USER" "$MASTER_DB_PASS" "$MASTER_DB_NAME"; then
        error "数据库连接失败，请检查：1.IP/端口/账号密码是否正确 2.主节点防火墙是否开放3306端口 3.数据库是否允许远程访问"
        return 1
    fi
    success "数据库连接测试成功"

    # API配置
    read -p "是否开启从节点API? [y/N]: " ENABLE_API
    ENABLE_API=${ENABLE_API,,}
    PDNS_API_KEY=""
    PDNS_API_PORT=8081
    PDNS_WEB_ALLOW_FROM="0.0.0.0/0"
    if [ "$ENABLE_API" = "y" ]; then
        PDNS_API_KEY=$(generate_random 32)
        read -p "API监听端口 [默认8081]: " PDNS_API_PORT
        PDNS_API_PORT=${PDNS_API_PORT:-8081}
        read -p "API允许访问的IP段 [默认0.0.0.0/0]: " PDNS_WEB_ALLOW_FROM
        PDNS_WEB_ALLOW_FROM=${PDNS_WEB_ALLOW_FROM:-0.0.0.0/0}
    fi

    # 配置PowerDNS从节点（自动备份）
    info "正在配置 PowerDNS 从节点..."
    if [ -f "$PDNS_CONF" ]; then
        cp "$PDNS_CONF" "$PDNS_CONF.bak.$BACKUP_SUFFIX"
        info "原有配置已备份"
    fi
    cat > "$PDNS_CONF" << EOF
# PowerDNS 从节点配置文件（自动生成）
setuid=pdns
setgid=pdns
local-address=0.0.0.0
local-port=53
master=no
slave=yes
disable-axfr=no
allow-axfr-ips=0.0.0.0/0
daemon=yes
guardian=yes
default-ttl=3600
max-ttl=604800
min-ttl=300

# MySQL 后端配置（连接主节点数据库）
launch=gmysql
gmysql-host=$MASTER_DB_HOST
gmysql-port=$MASTER_DB_PORT
gmysql-dbname=$MASTER_DB_NAME
gmysql-user=$MASTER_DB_USER
gmysql-password=$MASTER_DB_PASS
gmysql-dnssec=yes

# 日志配置
loglevel=3
logging-facility=0
log-dns-details=yes
log-dns-queries=yes
EOF

    # 添加API配置
    if [ "$ENABLE_API" = "y" ]; then
        cat >> "$PDNS_CONF" << EOF

# API 配置
api=yes
api-key=$PDNS_API_KEY
webserver=yes
webserver-address=0.0.0.0
webserver-port=$PDNS_API_PORT
webserver-allow-from=$PDNS_WEB_ALLOW_FROM
webserver-password=$PDNS_API_KEY
EOF
    fi

    # 删除默认bind后端冲突配置
    if [ -f "$PDNS_CONF_DIR/bind.conf" ]; then
        rm -f "$PDNS_CONF_DIR/bind.conf"
        info "已删除默认bind后端配置，避免启动冲突"
    fi
    success "PowerDNS 从节点配置完成"

    # 防火墙配置
    info "正在配置防火墙规则..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
        if ufw status | grep -q "active"; then
            ufw allow 53/tcp 2>/dev/null
            ufw allow 53/udp 2>/dev/null
            if [ "$ENABLE_API" = "y" ]; then
                ufw allow $PDNS_API_PORT/tcp 2>/dev/null
            fi
            ufw reload 2>/dev/null
            success "UFW 防火墙规则配置完成"
        else
            warn "UFW 防火墙未启用，跳过配置"
        fi
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=53/tcp 2>/dev/null
            firewall-cmd --permanent --add-port=53/udp 2>/dev/null
            if [ "$ENABLE_API" = "y" ]; then
                firewall-cmd --permanent --add-port=$PDNS_API_PORT/tcp 2>/dev/null
            fi
            firewall-cmd --reload 2>/dev/null
            success "Firewalld 防火墙规则配置完成"
        else
            warn "Firewalld 防火墙未启用，跳过配置"
        fi
    else
        warn "未检测到防火墙工具，跳过配置"
    fi

    # 启动服务
    info "正在启动 PowerDNS 从节点服务..."
    systemctl daemon-reload
    systemctl restart pdns
    if ! systemctl is-active --quiet pdns; then
        error "PowerDNS 服务启动失败，请查看日志：journalctl -xeu pdns"
        return 1
    fi
    systemctl enable pdns
    success "PowerDNS 从节点服务启动成功，已设置开机自启"

    # 输出结果
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="本机IP"
    fi
    echo ""
    success "================================= PowerDNS 从节点安装完成 =================================="
    info "PowerDNS 服务已启动，监听53端口（TCP/UDP）"
    info "节点IP: $SERVER_IP"
    if [ "$ENABLE_API" = "y" ]; then
        info "从节点API地址: http://$SERVER_IP:$PDNS_API_PORT"
        info "从节点API Key: $PDNS_API_KEY"
    fi
    info "主数据库连接: $MASTER_DB_HOST:$MASTER_DB_PORT"
    warn "请确保主节点数据库可被当前节点持续访问，防火墙已放行相关端口"
    success "============================================================================================"
    echo ""
}

# 3. PowerDNS 独立卸载（仅卸载PowerDNS，不碰PowerAdmin和数据库可选）
uninstall_pdns() {
    warn "警告：此操作将卸载 PowerDNS 服务及相关配置，不会影响 PowerAdmin 面板"
    read -p "是否继续卸载 PowerDNS? [y/N]: " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消卸载"
        return 0
    fi

    detect_os

    # 停止并禁用服务
    info "正在停止 PowerDNS 服务..."
    systemctl stop pdns &> /dev/null
    systemctl disable pdns &> /dev/null

    # 卸载软件包
    info "正在卸载 PowerDNS 相关软件包..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        $PM_REMOVE pdns-server pdns-backend-mysql
    else
        $PM_REMOVE pdns pdns-backend-mysql
    fi
    $PM_AUTOREMOVE

    # 删除配置文件和源
    info "正在删除 PowerDNS 残留配置..."
    rm -rf /etc/powerdns /etc/pdns
    rm -f /etc/apt/sources.list.d/powerdns-auth.list
    rm -f /etc/yum.repos.d/powerdns-auth.repo
    rm -rf /usr/share/keyrings/powerdns-archive-keyring.gpg

    # 询问是否清理防火墙规则
    read -p "是否清理 PowerDNS 相关防火墙规则(53/8081端口)? [y/N]: " CLEAN_FW
    CLEAN_FW=${CLEAN_FW,,}
    if [ "$CLEAN_FW" = "y" ]; then
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
            ufw delete allow 53/tcp &> /dev/null
            ufw delete allow 53/udp &> /dev/null
            ufw delete allow 8081/tcp &> /dev/null
            ufw reload &> /dev/null
        elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
            firewall-cmd --permanent --remove-port=53/tcp &> /dev/null
            firewall-cmd --permanent --remove-port=53/udp &> /dev/null
            firewall-cmd --permanent --remove-port=8081/tcp &> /dev/null
            firewall-cmd --reload &> /dev/null
        fi
        info "已清理 PowerDNS 相关防火墙规则"
    fi

    # 询问是否卸载MariaDB数据库
    if service_exists mariadb; then
        read -p "是否同时卸载 MariaDB 数据库? 【警告：会删除所有数据库数据，不可逆】 [y/N]: " UNINSTALL_DB
        UNINSTALL_DB=${UNINSTALL_DB,,}
        if [ "$UNINSTALL_DB" = "y" ]; then
            info "正在卸载 MariaDB 数据库..."
            systemctl stop mariadb &> /dev/null
            systemctl disable mariadb &> /dev/null
            if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
                $PM_REMOVE mariadb-server mariadb-client
            else
                $PM_REMOVE mariadb-server mariadb
            fi
            $PM_AUTOREMOVE
            rm -rf /var/lib/mysql /var/lib/mysql-files /var/lib/mysql-keyring
            success "MariaDB 数据库已卸载"
        fi
    fi

    # 询问是否恢复systemd-resolved配置
    read -p "是否恢复 systemd-resolved 的53端口占用配置? [y/N]: " RESTORE_RESOLVED
    RESTORE_RESOLVED=${RESTORE_RESOLVED,,}
    if [ "$RESTORE_RESOLVED" = "y" ]; then
        sed -i -E 's/#?DNSStubListener=no/DNSStubListener=yes/g' /etc/systemd/resolved.conf
        systemctl daemon-reload
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        info "已恢复 systemd-resolved 配置"
    fi

    success "================================= PowerDNS 卸载完成 =================================="
    info "PowerDNS 相关组件已全部卸载，PowerAdmin 面板不受影响"
    echo ""
}

# 4. PowerDNS 启动
start_pdns() {
    detect_os
    if ! service_exists pdns; then
        error "未检测到 PowerDNS 服务，请先安装 PowerDNS"
        return 1
    fi
    info "正在启动 PowerDNS 服务..."
    systemctl start pdns
    if systemctl is-active --quiet pdns; then
        success "PowerDNS 服务启动成功"
    else
        error "PowerDNS 服务启动失败，请查看日志：journalctl -xeu pdns"
    fi
}

# 5. PowerDNS 停止
stop_pdns() {
    detect_os
    if ! service_exists pdns; then
        error "未检测到 PowerDNS 服务，请先安装 PowerDNS"
        return 1
    fi
    info "正在停止 PowerDNS 服务..."
    systemctl stop pdns
    if ! systemctl is-active --quiet pdns; then
        success "PowerDNS 服务已停止"
    else
        error "PowerDNS 服务停止失败"
    fi
}

# 6. PowerDNS 重启
restart_pdns() {
    detect_os
    if ! service_exists pdns; then
        error "未检测到 PowerDNS 服务，请先安装 PowerDNS"
        return 1
    fi
    info "正在重启 PowerDNS 服务..."
    systemctl restart pdns
    if systemctl is-active --quiet pdns; then
        success "PowerDNS 服务重启成功"
    else
        error "PowerDNS 服务重启失败，请查看日志：journalctl -xeu pdns"
    fi
}

# 7. PowerDNS 设置开机自启
enable_pdns_autostart() {
    detect_os
    if ! service_exists pdns; then
        error "未检测到 PowerDNS 服务，请先安装 PowerDNS"
        return 1
    fi
    info "正在设置 PowerDNS 开机自启..."
    systemctl enable pdns
    if [ $? -eq 0 ]; then
        success "PowerDNS 开机自启设置成功"
    else
        error "开机自启设置失败"
    fi
}

# 8. PowerDNS 关闭开机自启
disable_pdns_autostart() {
    detect_os
    if ! service_exists pdns; then
        error "未检测到 PowerDNS 服务，请先安装 PowerDNS"
        return 1
    fi
    info "正在关闭 PowerDNS 开机自启..."
    systemctl disable pdns
    if [ $? -eq 0 ]; then
        success "PowerDNS 开机自启已关闭"
    else
        error "关闭开机自启失败"
    fi
}

# 9. PowerDNS 获取/重置 API Key
get_pdns_apikey() {
    detect_os
    if [ ! -f "$PDNS_CONF" ]; then
        error "PowerDNS 配置文件不存在，请先安装 PowerDNS"
        return 1
    fi

    # 读取当前API Key
    CURRENT_API_KEY=$(grep -E '^api-key=' "$PDNS_CONF" | cut -d= -f2)
    if [ -z "$CURRENT_API_KEY" ]; then
        warn "当前 PowerDNS 未开启API或未配置API Key"
        read -p "是否开启API并配置API Key? [y/N]: " ENABLE_API
        ENABLE_API=${ENABLE_API,,}
        if [ "$ENABLE_API" != "y" ]; then
            return 0
        fi
        # 生成并配置API
        NEW_API_KEY=$(generate_random 32)
        cp "$PDNS_CONF" "$PDNS_CONF.bak.$BACKUP_SUFFIX"
        cat >> "$PDNS_CONF" << EOF

# API 配置（自动生成）
api=yes
api-key=$NEW_API_KEY
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
webserver-allow-from=0.0.0.0/0
webserver-password=$NEW_API_KEY
EOF
        # 重启服务
        info "正在重启 PowerDNS 服务以应用配置..."
        systemctl restart pdns
        if [ $? -eq 0 ]; then
            success "API 已开启"
            info "新的 API Key: $NEW_API_KEY"
            info "API 地址: http://$(hostname -I | awk '{print $1}'):8081"
        else
            error "PowerDNS 服务重启失败，请检查配置文件"
            return 1
        fi
        return 0
    fi

    # 输出当前API Key
    echo ""
    info "当前 PowerDNS API Key: $CURRENT_API_KEY"
    API_PORT=$(grep -E '^webserver-port=' "$PDNS_CONF" | cut -d= -f2)
    API_PORT=${API_PORT:-8081}
    info "API 监听端口: $API_PORT"
    echo ""

    # 重置API Key
    read -p "是否重置 API Key? [y/N]: " RESET_KEY
    RESET_KEY=${RESET_KEY,,}
    if [ "$RESET_KEY" != "y" ]; then
        return 0
    fi

    # 生成新Key并更新配置
    NEW_API_KEY=$(generate_random 32)
    cp "$PDNS_CONF" "$PDNS_CONF.bak.$BACKUP_SUFFIX"
    sed -i "s/^api-key=.*/api-key=$NEW_API_KEY/g" "$PDNS_CONF"
    sed -i "s/^webserver-password=.*/webserver-password=$NEW_API_KEY/g" "$PDNS_CONF"
    # 重启服务
    info "正在重启 PowerDNS 服务以应用新的API Key..."
    systemctl restart pdns
    if [ $? -eq 0 ]; then
        success "API Key 重置成功"
        info "新的 API Key: $NEW_API_KEY"
        warn "请同步更新 PowerAdmin 等对接API的服务的配置"
    else
        error "PowerDNS 服务重启失败，请检查配置文件"
        return 1
    fi
}

# ===================== PowerAdmin 专属功能函数（完全独立） =====================
# 1. PowerAdmin 独立安装（仅安装面板，适配本地/远程PowerDNS，不碰PowerDNS服务）
install_poweradmin() {
    info "开始独立安装 PowerAdmin 管理面板（仅安装面板，不修改PowerDNS服务）"
    detect_os

    # 前置检查
    if [ -d "$POWERADMIN_WEB_ROOT" ]; then
        warn "检测到 PowerAdmin 已安装，重复安装将覆盖原有站点，配置和站点文件将自动备份"
        read -p "是否继续安装? [y/N]: " CONFIRM
        CONFIRM=${CONFIRM,,}
        if [ "$CONFIRM" != "y" ]; then
            info "已取消安装"
            return 0
        fi
    fi

    # 更新系统包
    info "正在更新系统包..."
    $PM_UPDATE
    if [ $? -ne 0 ]; then
        warn "系统包更新失败，不影响核心安装"
    fi

    # 安装基础依赖
    info "正在安装基础依赖..."
    $PM_INSTALL curl wget gnupg2 ca-certificates
    if [ $? -ne 0 ]; then
        error "基础依赖安装失败"
        return 1
    fi

    # 安装Nginx和PHP环境（自动适配已安装的情况）
    info "正在检查并安装 Nginx + PHP 环境..."
    local NGINX_INSTALLED=0
    local PHP_INSTALLED=0
    if service_exists nginx; then
        NGINX_INSTALLED=1
        info "检测到 Nginx 已安装，跳过安装"
    fi
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if service_exists php*-fpm; then
            PHP_INSTALLED=1
            info "检测到 PHP-FPM 已安装，跳过安装"
        fi
    else
        if service_exists php-fpm; then
            PHP_INSTALLED=1
            info "检测到 PHP-FPM 已安装，跳过安装"
        fi
    fi

    # 安装缺失的组件
    if [ $NGINX_INSTALLED -eq 0 ] || [ $PHP_INSTALLED -eq 0 ]; then
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
            $PM_INSTALL nginx php-fpm php-mysql php-curl php-mbstring php-xml php-gd php-intl
            # 获取PHP版本
            if command -v php &> /dev/null; then
                PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
                PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
            else
                error "PHP 安装失败"
                return 1
            fi
        else
            $PM_INSTALL nginx php-fpm php-mysqlnd php-curl php-mbstring php-xml php-gd php-intl
            PHP_FPM_SERVICE="php-fpm"
        fi
        if [ $? -ne 0 ]; then
            error "Nginx/PHP 环境安装失败"
            return 1
        fi
        success "Nginx/PHP 环境安装完成"
    else
        # 已安装，获取PHP服务名
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
            PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        else
            PHP_FPM_SERVICE="php-fpm"
        fi
    fi

    # 启动并确保PHP-FPM和Nginx正常
    info "正在启动 Nginx 和 PHP-FPM 服务..."
    systemctl start $PHP_FPM_SERVICE
    systemctl enable $PHP_FPM_SERVICE
    if ! systemctl is-active --quiet $PHP_FPM_SERVICE; then
        error "PHP-FPM 服务启动失败，请查看日志：journalctl -xeu $PHP_FPM_SERVICE"
        return 1
    fi
    if [ $NGINX_INSTALLED -eq 0 ]; then
        systemctl start nginx
        systemctl enable nginx
    fi
    if ! systemctl is-active --quiet nginx; then
        error "Nginx 服务启动失败，请查看日志：journalctl -xeu nginx"
        return 1
    fi
    success "Nginx/PHP 服务运行正常"

    # 获取PowerDNS数据库和API信息
    echo -e "\033[33m请输入 PowerDNS 数据库配置信息（安装PowerDNS主节点时生成）：\033[0m"
    read -p "数据库IP地址 [默认127.0.0.1]: " DB_HOST
    DB_HOST=${DB_HOST:-127.0.0.1}
    read -p "数据库端口 [默认3306]: " DB_PORT
    DB_PORT=${DB_PORT:-3306}
    read -p "PowerDNS数据库名 [默认powerdns]: " DB_NAME
    DB_NAME=${DB_NAME:-powerdns}
    read -p "数据库用户名 [默认powerdns]: " DB_USER
    DB_USER=${DB_USER:-powerdns}
    read -s -p "数据库密码: " DB_PASS
    echo ""
    if [ -z "$DB_PASS" ]; then
        error "数据库密码不能为空"
        return 1
    fi

    # 测试数据库连接
    info "正在测试数据库连接..."
    if ! command -v mysql &> /dev/null; then
        info "正在安装mysql客户端用于测试连接..."
        $PM_INSTALL mariadb-client
    fi
    if ! check_mysql_login "$DB_HOST" "$DB_PORT" "$DB_USER" "$DB_PASS" "$DB_NAME"; then
        error "数据库连接失败，请检查IP、端口、账号密码是否正确，以及数据库远程访问权限"
        return 1
    fi
    # 检查是否是PowerDNS数据库
    TABLE_EXIST=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SHOW TABLES LIKE 'domains';" 2>/dev/null | wc -l)
    if [ "$TABLE_EXIST" -eq 0 ]; then
        warn "未检测到PowerDNS核心表，该数据库可能不是PowerDNS使用的数据库"
        read -p "是否继续安装? [y/N]: " CONFIRM
        if [ "$CONFIRM" != "y" ]; then
            info "已取消安装"
            return 0
        fi
    fi
    success "数据库连接验证通过"

    # 获取PowerDNS API信息
    echo -e "\033[33m请输入 PowerDNS API 配置信息（安装PowerDNS主节点时生成）：\033[0m"
    read -p "PowerDNS API地址 [默认http://127.0.0.1:8081]: " API_URL
    API_URL=${API_URL:-http://127.0.0.1:8081}
    read -p "PowerDNS API Key: " API_KEY
    if [ -z "$API_KEY" ]; then
        error "API Key 不能为空"
        return 1
    fi
    # 测试API连通性
    info "正在测试 PowerDNS API 连通性..."
    API_TEST=$(curl -s -o /dev/null -w "%{http_code}" -H "X-API-Key: $API_KEY" "$API_URL/api/v1/servers/localhost")
    if [ "$API_TEST" -ne 200 ]; then
        warn "API 连接失败，状态码：$API_TEST，请检查API地址、Key是否正确，以及PowerDNS服务是否正常运行"
        read -p "是否继续安装? [y/N]: " CONFIRM
        if [ "$CONFIRM" != "y" ]; then
            info "已取消安装"
            return 0
        fi
    else
        success "PowerDNS API 连接验证通过"
    fi

    # 下载并部署PowerAdmin
    POWERADMIN_VERSION="3.8.0"
    info "正在下载 PowerAdmin v$POWERADMIN_VERSION 源码..."
    wget -O /tmp/poweradmin.tar.gz https://github.com/poweradmin/poweradmin/archive/refs/tags/v$POWERADMIN_VERSION.tar.gz
    if [ $? -ne 0 ]; then
        error "PowerAdmin 源码下载失败，请检查网络连接"
        return 1
    fi
    # 解压
    tar -zxf /tmp/poweradmin.tar.gz -C /tmp
    if [ ! -d /tmp/poweradmin-$POWERADMIN_VERSION ]; then
        error "PowerAdmin 源码解压失败"
        return 1
    fi
    # 备份原有站点
    if [ -d "$POWERADMIN_WEB_ROOT" ]; then
        mv "$POWERADMIN_WEB_ROOT" "$POWERADMIN_WEB_ROOT.bak.$BACKUP_SUFFIX"
        info "原有PowerAdmin站点已备份至 $POWERADMIN_WEB_ROOT.bak.$BACKUP_SUFFIX"
    fi
    # 部署新站点
    mv /tmp/poweradmin-$POWERADMIN_VERSION "$POWERADMIN_WEB_ROOT"
    # 设置权限
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        chown -R www-data:www-data "$POWERADMIN_WEB_ROOT"
    else
        chown -R nginx:nginx "$POWERADMIN_WEB_ROOT"
    fi
    chmod -R 755 "$POWERADMIN_WEB_ROOT"
    success "PowerAdmin 源码部署完成"

    # 导入PowerAdmin表结构（容错）
    info "正在检查并导入 PowerAdmin 表结构..."
    ADMIN_TABLE_EXIST=$(mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" -e "SHOW TABLES LIKE 'users';" 2>/dev/null | wc -l)
    if [ "$ADMIN_TABLE_EXIST" -eq 0 ]; then
        info "未检测到PowerAdmin表结构，正在导入..."
        POWERADMIN_SQL="$POWERADMIN_WEB_ROOT/install/poweradmin-mysql-db-structure.sql"
        if [ ! -f "$POWERADMIN_SQL" ]; then
            error "PowerAdmin 表结构文件不存在：$POWERADMIN_SQL"
            return 1
        fi
        mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" < "$POWERADMIN_SQL"
        if [ $? -ne 0 ]; then
            error "PowerAdmin 表结构导入失败"
            return 1
        fi
        success "PowerAdmin 表结构导入完成"
    else
        warn "检测到PowerAdmin表结构已存在，跳过导入步骤"
    fi

    # 生成管理员账号密码
    POWERADMIN_ADMIN_USER="admin"
    POWERADMIN_ADMIN_PASS=$(generate_random 16)
    POWERADMIN_ADMIN_PASS_HASH=$(php -r "echo password_hash('$POWERADMIN_ADMIN_PASS', PASSWORD_DEFAULT);")
    # 更新管理员密码（确保可以登录）
    info "正在更新管理员账号密码..."
    mysql -h "$DB_HOST" -P "$DB_PORT" -u "$DB_USER" -p"$DB_PASS" "$DB_NAME" << EOF
UPDATE users SET password='$POWERADMIN_ADMIN_PASS_HASH' WHERE username='$POWERADMIN_ADMIN_USER';
EOF
    if [ $? -ne 0 ]; then
        warn "管理员密码更新失败，请检查users表是否存在"
    fi

    # 生成PowerAdmin配置文件
    info "正在生成 PowerAdmin 配置文件..."
    if [ -f "$POWERADMIN_WEB_ROOT/inc/config.inc.php" ]; then
        cp "$POWERADMIN_WEB_ROOT/inc/config.inc.php" "$POWERADMIN_WEB_ROOT/inc/config.inc.php.bak.$BACKUP_SUFFIX"
        info "原有配置文件已备份"
    fi
    cat > "$POWERADMIN_WEB_ROOT/inc/config.inc.php" << EOF
<?php
\$db_host = '$DB_HOST';
\$db_user = '$DB_USER';
\$db_pass = '$DB_PASS';
\$db_name = '$DB_NAME';
\$db_port = '$DB_PORT';
\$db_charset = 'utf8mb4';

\$session_key = '$(generate_random 32)';
\$iface_lang = 'en_EN';
\$dns_hostmaster = 'hostmaster@example.com';
\$dns_ns1 = 'ns1.example.com';
\$dns_ns2 = 'ns2.example.com';

\$pdns_api_url = '$API_URL';
\$pdns_api_key = '$API_KEY';
\$pdns_api_verify_ssl = false;
?>
EOF
    # 设置配置文件权限
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        chown www-data:www-data "$POWERADMIN_WEB_ROOT/inc/config.inc.php"
    else
        chown nginx:nginx "$POWERADMIN_WEB_ROOT/inc/config.inc.php"
    fi
    chmod 640 "$POWERADMIN_WEB_ROOT/inc/config.inc.php"
    success "PowerAdmin 配置文件生成完成"

    # 配置Nginx虚拟主机
    info "正在配置 Nginx 虚拟主机..."
    # 备份原有配置
    if [ -f "$NGINX_CONF_PATH" ]; then
        cp "$NGINX_CONF_PATH" "$NGINX_CONF_PATH.bak.$BACKUP_SUFFIX"
        info "原有Nginx配置已备份"
    fi
    # 生成新配置
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        cat > "$NGINX_CONF_PATH" << EOF
server {
    listen 80;
    server_name _;
    root $POWERADMIN_WEB_ROOT;
    index index.php index.html index.htm;

    access_log /var/log/nginx/poweradmin_access.log;
    error_log /var/log/nginx/poweradmin_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/run/php/$PHP_FPM_SERVICE.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location /install/ {
        deny all;
        return 403;
    }
}
EOF
        # 禁用默认站点
        if [ -f /etc/nginx/sites-enabled/default ]; then
            rm -f /etc/nginx/sites-enabled/default
        fi
        ln -sf "$NGINX_CONF_PATH" "$NGINX_ENABLED_PATH"
    else
        cat > "$NGINX_CONF_PATH" << EOF
server {
    listen 80;
    server_name _;
    root $POWERADMIN_WEB_ROOT;
    index index.php index.html index.htm;

    access_log /var/log/nginx/poweradmin_access.log;
    error_log /var/log/nginx/poweradmin_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:/run/php-fpm/www.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    location /install/ {
        deny all;
        return 403;
    }
}
EOF
    fi
    # 测试Nginx配置
    nginx -t
    if [ $? -ne 0 ]; then
        error "Nginx 配置文件有误，请检查配置"
        return 1
    fi
    # 重启Nginx
    systemctl restart nginx
    if ! systemctl is-active --quiet nginx; then
        error "Nginx 服务重启失败"
        return 1
    fi
    success "Nginx 虚拟主机配置完成"

    # 配置SELinux（RHEL系）
    if [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        info "正在配置 SELinux 规则..."
        if command -v setsebool &> /dev/null; then
            setsebool -P httpd_can_network_connect on 2>/dev/null
            setsebool -P httpd_can_network_connect_db on 2>/dev/null
            chcon -R -t httpd_sys_content_t "$POWERADMIN_WEB_ROOT" 2>/dev/null
            chcon -R -t httpd_sys_rw_content_t "$POWERADMIN_WEB_ROOT/inc" 2>/dev/null
            if [ $? -eq 0 ]; then
                success "SELinux 规则配置完成"
            else
                warn "SELinux 规则配置失败，请手动检查"
            fi
        else
            warn "未检测到SELinux工具，跳过配置"
        fi
    fi

    # 配置防火墙
    info "正在配置防火墙规则..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
        if ufw status | grep -q "active"; then
            ufw allow 80/tcp 2>/dev/null
            ufw reload 2>/dev/null
            success "UFW 防火墙80端口已放行"
        else
            warn "UFW 防火墙未启用，跳过配置"
        fi
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
        if systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=80/tcp 2>/dev/null
            firewall-cmd --reload 2>/dev/null
            success "Firewalld 防火墙80端口已放行"
        else
            warn "Firewalld 防火墙未启用，跳过配置"
        fi
    else
        warn "未检测到防火墙工具，跳过配置"
    fi

    # 获取服务器IP
    SERVER_IP=$(hostname -I | awk '{print $1}')
    if [ -z "$SERVER_IP" ]; then
        SERVER_IP="本机IP"
    fi

    # 输出安装结果
    echo ""
    success "================================= PowerAdmin 安装完成 =================================="
    info "【管理面板访问信息】"
    info "访问地址: http://$SERVER_IP"
    info "管理员账号: $POWERADMIN_ADMIN_USER"
    info "管理员密码: $POWERADMIN_ADMIN_PASS"
    echo ""
    info "【配置信息】"
    info "PowerDNS 数据库连接: $DB_HOST:$DB_PORT"
    info "PowerDNS API 地址: $API_URL"
    echo ""
    warn "【重要提示】"
    warn "1. 请妥善保存管理员账号密码，丢失可通过脚本重新安装重置"
    warn "2. 请登录面板后及时修改默认的NS配置和hostmaster邮箱"
    warn "3. 生产环境建议配置HTTPS访问，修改Nginx配置添加SSL证书即可"
    success "========================================================================================"
    echo ""
}

# 2. PowerAdmin 独立卸载（仅卸载面板，不碰PowerDNS和数据库）
uninstall_poweradmin() {
    warn "警告：此操作将卸载 PowerAdmin 管理面板、Nginx、PHP 相关组件，不会影响 PowerDNS 服务和数据库数据"
    read -p "是否继续卸载 PowerAdmin? [y/N]: " CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        info "已取消卸载"
        return 0
    fi

    detect_os

    # 停止相关服务
    info "正在停止 PowerAdmin 相关服务（Nginx/PHP-FPM）..."
    systemctl stop nginx $PHP_FPM_SERVICE &> /dev/null

    # 询问是否卸载Nginx和PHP
    read -p "是否同时卸载 Nginx 和 PHP 环境? [y/N]: " UNINSTALL_WEB
    UNINSTALL_WEB=${UNINSTALL_WEB,,}
    if [ "$UNINSTALL_WEB" = "y" ]; then
        info "正在卸载 Nginx 和 PHP 环境..."
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
            $PM_REMOVE nginx php*
        else
            $PM_REMOVE nginx php*
        fi
        $PM_AUTOREMOVE
        success "Nginx 和 PHP 环境已卸载"
    else
        systemctl disable nginx $PHP_FPM_SERVICE &> /dev/null
        info "已停止 Nginx 和 PHP 服务，未卸载软件包"
    fi

    # 删除PowerAdmin站点文件和配置
    info "正在删除 PowerAdmin 相关文件和配置..."
    rm -rf $POWERADMIN_WEB_ROOT $POWERADMIN_WEB_ROOT.bak.*
    rm -f /etc/nginx/sites-available/poweradmin.conf /etc/nginx/sites-enabled/poweradmin.conf
    rm -f /etc/nginx/conf.d/poweradmin.conf
    rm -rf /var/log/nginx/poweradmin_*.log
    rm -rf /tmp/poweradmin*

    # 询问是否清理防火墙规则
    read -p "是否清理 PowerAdmin 相关防火墙规则(80端口)? [y/N]: " CLEAN_FW
    CLEAN_FW=${CLEAN_FW,,}
    if [ "$CLEAN_FW" = "y" ]; then
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
            ufw delete allow 80/tcp &> /dev/null
            ufw reload &> /dev/null
        elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
            firewall-cmd --permanent --remove-port=80/tcp &> /dev/null
            firewall-cmd --reload &> /dev/null
        fi
        info "已清理 80 端口防火墙规则"
    fi

    success "================================= PowerAdmin 卸载完成 =================================="
    info "PowerAdmin 面板相关组件已全部卸载，PowerDNS 服务和数据库不受影响"
    echo ""
}

# 3. PowerAdmin 启动（启动Nginx+PHP）
start_poweradmin() {
    detect_os
    # 自动获取PHP服务名
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if command -v php &> /dev/null; then
            PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        else
            PHP_FPM_SERVICE="php*-fpm"
        fi
    else
        PHP_FPM_SERVICE="php-fpm"
    fi

    if ! service_exists nginx; then
        error "未检测到 Nginx 服务，请先安装 PowerAdmin"
        return 1
    fi

    info "正在启动 PowerAdmin 相关服务（Nginx+PHP-FPM）..."
    systemctl start nginx $PHP_FPM_SERVICE
    if systemctl is-active --quiet nginx && systemctl is-active --quiet $PHP_FPM_SERVICE; then
        success "PowerAdmin 相关服务启动成功"
    else
        error "部分服务启动失败，请检查 Nginx 和 PHP-FPM 服务状态"
    fi
}

# 4. PowerAdmin 停止（停止Nginx+PHP）
stop_poweradmin() {
    detect_os
    # 自动获取PHP服务名
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if command -v php &> /dev/null; then
            PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        else
            PHP_FPM_SERVICE="php*-fpm"
        fi
    else
        PHP_FPM_SERVICE="php-fpm"
    fi

    if ! service_exists nginx; then
        error "未检测到 Nginx 服务，请先安装 PowerAdmin"
        return 1
    fi

    info "正在停止 PowerAdmin 相关服务（Nginx+PHP-FPM）..."
    systemctl stop nginx $PHP_FPM_SERVICE
    if ! systemctl is-active --quiet nginx && ! systemctl is-active --quiet $PHP_FPM_SERVICE; then
        success "PowerAdmin 相关服务已停止"
    else
        error "部分服务停止失败"
    fi
}

# 5. PowerAdmin 重启（重启Nginx+PHP）
restart_poweradmin() {
    detect_os
    # 自动获取PHP服务名
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if command -v php &> /dev/null; then
            PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        else
            PHP_FPM_SERVICE="php*-fpm"
        fi
    else
        PHP_FPM_SERVICE="php-fpm"
    fi

    if ! service_exists nginx; then
        error "未检测到 Nginx 服务，请先安装 PowerAdmin"
        return 1
    fi

    info "正在重启 PowerAdmin 相关服务（Nginx+PHP-FPM）..."
    systemctl restart nginx $PHP_FPM_SERVICE
    if systemctl is-active --quiet nginx && systemctl is-active --quiet $PHP_FPM_SERVICE; then
        success "PowerAdmin 相关服务重启成功"
    else
        error "部分服务重启失败，请查看日志"
    fi
}

# 6. PowerAdmin 设置开机自启
enable_poweradmin_autostart() {
    detect_os
    # 自动获取PHP服务名
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if command -v php &> /dev/null; then
            PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        else
            PHP_FPM_SERVICE="php*-fpm"
        fi
    else
        PHP_FPM_SERVICE="php-fpm"
    fi

    if ! service_exists nginx; then
        error "未检测到 Nginx 服务，请先安装 PowerAdmin"
        return 1
    fi

    info "正在设置 PowerAdmin 相关服务开机自启（Nginx+PHP-FPM）..."
    systemctl enable nginx $PHP_FPM_SERVICE
    if [ $? -eq 0 ]; then
        success "PowerAdmin 相关服务开机自启设置成功"
    else
        error "开机自启设置失败"
    fi
}

# 7. PowerAdmin 关闭开机自启
disable_poweradmin_autostart() {
    detect_os
    # 自动获取PHP服务名
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if command -v php &> /dev/null; then
            PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        else
            PHP_FPM_SERVICE="php*-fpm"
        fi
    else
        PHP_FPM_SERVICE="php-fpm"
    fi

    if ! service_exists nginx; then
        error "未检测到 Nginx 服务，请先安装 PowerAdmin"
        return 1
    fi

    info "正在关闭 PowerAdmin 相关服务开机自启（Nginx+PHP-FPM）..."
    systemctl disable nginx $PHP_FPM_SERVICE
    if [ $? -eq 0 ]; then
        success "PowerAdmin 相关服务开机自启已关闭"
    else
        error "关闭开机自启失败"
    fi
}

# ===================== 通用辅助功能 =====================
# 查看所有服务状态
show_all_status() {
    detect_os
    # 自动获取PHP服务名
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if command -v php &> /dev/null; then
            PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
            PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
        else
            PHP_FPM_SERVICE=""
        fi
    else
        PHP_FPM_SERVICE="php-fpm"
    fi

    echo ""
    info "================================= 全服务运行状态 =================================="
    # PowerDNS 服务
    if service_exists pdns; then
        if systemctl is-active --quiet pdns; then
            echo -e "PowerDNS 服务: \033[32m运行中\033[0m | 开机自启: $(systemctl is-enabled pdns 2>/dev/null)"
        else
            echo -e "PowerDNS 服务: \033[31m已停止\033[0m | 开机自启: $(systemctl is-enabled pdns 2>/dev/null)"
        fi
    else
        echo -e "PowerDNS 服务: \033[90m未安装\033[0m"
    fi

    # MariaDB 服务
    if service_exists mariadb; then
        if systemctl is-active --quiet mariadb; then
            echo -e "MariaDB 数据库: \033[32m运行中\033[0m | 开机自启: $(systemctl is-enabled mariadb 2>/dev/null)"
        else
            echo -e "MariaDB 数据库: \033[31m已停止\033[0m | 开机自启: $(systemctl is-enabled mariadb 2>/dev/null)"
        fi
    else
        echo -e "MariaDB 数据库: \033[90m未安装\033[0m"
    fi

    # Nginx 服务
    if service_exists nginx; then
        if systemctl is-active --quiet nginx; then
            echo -e "Nginx 服务: \033[32m运行中\033[0m | 开机自启: $(systemctl is-enabled nginx 2>/dev/null)"
        else
            echo -e "Nginx 服务: \033[31m已停止\033[0m | 开机自启: $(systemctl is-enabled nginx 2>/dev/null)"
        fi
    else
        echo -e "Nginx 服务: \033[90m未安装\033[0m"
    fi

    # PHP-FPM 服务
    if [ -n "$PHP_FPM_SERVICE" ] && service_exists $PHP_FPM_SERVICE; then
        if systemctl is-active --quiet $PHP_FPM_SERVICE; then
            echo -e "PHP-FPM 服务: \033[32m运行中\033[0m | 开机自启: $(systemctl is-enabled $PHP_FPM_SERVICE 2>/dev/null)"
        else
            echo -e "PHP-FPM 服务: \033[31m已停止\033[0m | 开机自启: $(systemctl is-enabled $PHP_FPM_SERVICE 2>/dev/null)"
        fi
    else
        echo -e "PHP-FPM 服务: \033[90m未安装\033[0m"
    fi

    echo ""
    info "================================= 端口监听状态 =================================="
    echo "53端口(DNS TCP/UDP):"
    ss -lnp | grep -E ':53\s' 2>/dev/null || echo "未监听"
    echo ""
    echo "80端口(Web管理面板):"
    ss -lnp | grep -E ':80\s' 2>/dev/null || echo "未监听"
    echo ""
    echo "8081端口(PowerDNS API):"
    ss -lnp | grep -E ':8081\s' 2>/dev/null || echo "未监听"
    echo ""
}

# ===================== 主菜单（分类清晰，完全分离） =====================
main() {
    # 检查root权限
    if [ "$(id -u)" -ne 0 ]; then
        error "必须使用root权限运行此脚本，请使用sudo或切换到root用户"
        exit 1
    fi

    # 预检测系统
    detect_os

    # 菜单循环
    while true; do
        echo ""
        echo "==================== PowerDNS & PowerAdmin 全分离管理脚本 ===================="
        echo "---------------------- 【PowerDNS 专属功能】 ----------------------"
        echo "1.  安装 PowerDNS 主节点（含数据库、API）"
        echo "2.  安装 PowerDNS 从节点（多节点扩展）"
        echo "3.  卸载 PowerDNS 服务（独立卸载）"
        echo "4.  启动 PowerDNS 服务"
        echo "5.  停止 PowerDNS 服务"
        echo "6.  重启 PowerDNS 服务"
        echo "7.  设置 PowerDNS 开机自启"
        echo "8.  关闭 PowerDNS 开机自启"
        echo "9.  获取/重置 PowerDNS API Key"
        echo "---------------------- 【PowerAdmin 专属功能】 ----------------------"
        echo "10. 安装 PowerAdmin 管理面板（独立安装）"
        echo "11. 卸载 PowerAdmin 管理面板（独立卸载）"
        echo "12. 启动 PowerAdmin 相关服务（Nginx+PHP）"
        echo "13. 停止 PowerAdmin 相关服务（Nginx+PHP）"
        echo "14. 重启 PowerAdmin 相关服务（Nginx+PHP）"
        echo "15. 设置 PowerAdmin 开机自启"
        echo "16. 关闭 PowerAdmin 开机自启"
        echo "---------------------- 【通用辅助功能】 ----------------------"
        echo "17. 查看所有服务运行状态"
        echo "0.  退出脚本"
        echo "================================================================================"
        read -p "请输入您的选择 [
