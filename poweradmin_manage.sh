#!/bin/bash
set -o pipefail

# ========================== 颜色输出定义 ==========================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
NC='\033[0m'

# ========================== 可配置参数（按需修改） ==========================
# 数据库核心配置
DB_ROOT_PASS=$(openssl rand -hex 8)    # 数据库root密码，默认随机生成，可自定义固定值
DB_PDNS_NAME="powerdns"                 # PowerDNS使用的数据库名
DB_PDNS_USER="pdns"                      # PowerDNS数据库用户名
DB_PDNS_PASS=$(openssl rand -hex 8)     # PowerDNS数据库密码，默认随机生成，可自定义固定值

# PowerDNS核心配置
PDNS_API_KEY=$(openssl rand -hex 16)    # PowerDNS API密钥，默认32位随机生成，可自定义
PDNS_WEBSERVER_PORT="8081"              # PowerDNS API/WebServer端口
PDNS_ALLOW_FROM="127.0.0.1,::1,0.0.0.0/0"  # API访问白名单，生产环境请修改为可信IP段
PDNS_MASTER="no"
PDNS_SLAVE="no"

# PowerAdmin面板配置
POWERADMIN_VERSION="latest"              # 面板版本，latest为最新稳定版，可指定如v3.8.2
POWERADMIN_WEB_ROOT="/var/www/poweradmin" # 面板安装目录
POWERADMIN_NGINX_CONF="/etc/nginx/conf.d/poweradmin.conf" # Nginx配置路径

# 系统级配置
DISABLE_SYSTEMD_RESOLVED="yes"           # 自动禁用systemd-resolved（解决53端口占用，必开）
CONFIGURE_FIREWALL="yes"                 # 自动配置防火墙规则
# ==========================================================================

# ========================== 通用基础函数 ==========================
# 检查root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}错误：此脚本必须以root用户运行，请使用sudo或切换到root用户后执行${NC}"
        exit 1
    fi
}

# 操作系统检测与包管理器适配
check_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
        VERSION_CODENAME=${VERSION_CODENAME:-}
    else
        echo -e "${RED}错误：无法识别操作系统，仅支持Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux${NC}"
        exit 1
    fi

    # 适配包管理器
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        PKG_MANAGER="apt"
        PKG_INSTALL="$PKG_MANAGER install -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold"
        PKG_REMOVE="$PKG_MANAGER remove -y --purge"
        PKG_UPDATE="$PKG_MANAGER update -y"
        PKG_UPGRADE="$PKG_MANAGER upgrade -y"
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        PKG_MANAGER="dnf"
        if ! command -v dnf &> /dev/null; then
            PKG_MANAGER="yum"
        fi
        PKG_INSTALL="$PKG_MANAGER install -y"
        PKG_REMOVE="$PKG_MANAGER remove -y"
        PKG_UPDATE="$PKG_MANAGER makecache -y"
        PKG_UPGRADE="$PKG_MANAGER upgrade -y"
    else
        echo -e "${RED}错误：不支持的操作系统 $OS，仅支持Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux${NC}"
        exit 1
    fi

    echo -e "${GREEN}检测到操作系统：$OS $VERSION_ID，包管理器：$PKG_MANAGER${NC}"
}

# 处理53端口占用（systemd-resolved）
handle_port_53() {
    if [ "$DISABLE_SYSTEMD_RESOLVED" != "yes" ]; then
        echo -e "${YELLOW}跳过systemd-resolved处理，53端口占用将导致PowerDNS启动失败${NC}"
        return 0
    fi

    echo -e "${BLUE}正在释放53端口，禁用systemd-resolved DNSStubListener${NC}"
    
    if systemctl is-active --quiet systemd-resolved; then
        # 修改配置关闭DNSStubListener
        sed -i 's/#DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
        sed -i 's/DNSStubListener=yes/DNSStubListener=no/' /etc/systemd/resolved.conf
        
        # 重启服务并更新resolv.conf
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        
        echo -e "${GREEN}53端口释放完成，systemd-resolved DNSStub已禁用${NC}"
    else
        echo -e "${GREEN}systemd-resolved未运行，无需处理53端口${NC}"
    fi

    # 端口占用二次检查
    if ss -tulpn | grep -q ':53 '; then
        echo -e "${YELLOW}警告：53端口仍被以下进程占用，请手动关闭后再继续：${NC}"
        ss -tulpn | grep ':53 '
    fi
}

# 防火墙规则配置
configure_firewall() {
    if [ "$CONFIGURE_FIREWALL" != "yes" ]; then
        echo -e "${YELLOW}跳过防火墙配置${NC}"
        return 0
    fi

    echo -e "${BLUE}正在配置防火墙规则${NC}"
    PORTS=("53/tcp" "53/udp" "80/tcp" "${PDNS_WEBSERVER_PORT}/tcp")

    # Debian/Ubuntu UFW适配
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
            for port in "${PORTS[@]}"; do
                ufw allow "$port" > /dev/null 2>&1
            done
            ufw reload > /dev/null 2>&1
            echo -e "${GREEN}UFW防火墙规则添加完成${NC}"
        else
            echo -e "${YELLOW}UFW未启用，跳过防火墙配置${NC}"
        fi
    # RHEL系 Firewalld适配
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        if systemctl is-active --quiet firewalld; then
            for port in "${PORTS[@]}"; do
                firewall-cmd --permanent --add-port="$port" > /dev/null 2>&1
            done
            firewall-cmd --reload > /dev/null 2>&1
            echo -e "${GREEN}Firewalld防火墙规则添加完成${NC}"
        else
            echo -e "${YELLOW}Firewalld未启用，跳过防火墙配置${NC}"
        fi
    fi
}

# 安装基础依赖
install_deps() {
    echo -e "${BLUE}正在更新系统源并安装基础依赖${NC}"
    
    if ! $PKG_UPDATE; then
        echo -e "${RED}错误：系统源更新失败，请检查网络或源配置${NC}"
        exit 1
    fi

    BASE_DEPS=("curl" "wget" "gnupg2" "openssl" "sudo" "lsof" "iproute2" "tar" "unzip")
    if ! $PKG_INSTALL "${BASE_DEPS[@]}"; then
        echo -e "${RED}错误：基础依赖安装失败${NC}"
        exit 1
    fi

    echo -e "${GREEN}基础依赖安装完成${NC}"
}

# 安装并初始化MariaDB数据库
install_mariadb() {
    echo -e "${BLUE}正在安装并配置MariaDB数据库${NC}"

    # 适配不同发行版的包名
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        MARIADB_PKGS=("mariadb-server" "mariadb-client")
    else
        MARIADB_PKGS=("mariadb-server" "mariadb")
    fi

    if ! $PKG_INSTALL "${MARIADB_PKGS[@]}"; then
        echo -e "${RED}错误：MariaDB安装失败${NC}"
        exit 1
    fi

    # 启动并启用开机自启
    systemctl enable --now mariadb
    if ! systemctl is-active --quiet mariadb; then
        echo -e "${RED}错误：MariaDB服务启动失败${NC}"
        exit 1
    fi

    # 配置root用户密码与认证方式
    echo -e "${BLUE}正在初始化数据库root用户${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        # 处理Debian/Ubuntu默认的unix_socket认证
        mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
UPDATE mysql.user SET plugin='mysql_native_password' WHERE User='root';
FLUSH PRIVILEGES;
EOF
    else
        # RHEL系初始root密码为空
        mysql -u root << EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
FLUSH PRIVILEGES;
EOF
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：数据库root用户配置失败${NC}"
        exit 1
    fi

    # 创建PowerDNS专用数据库与用户
    echo -e "${BLUE}正在创建PowerDNS数据库与用户${NC}"
    mysql -u root -p"$DB_ROOT_PASS" << EOF
CREATE DATABASE IF NOT EXISTS $DB_PDNS_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$DB_PDNS_USER'@'localhost' IDENTIFIED BY '$DB_PDNS_PASS';
GRANT ALL PRIVILEGES ON $DB_PDNS_NAME.* TO '$DB_PDNS_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：PowerDNS数据库创建失败${NC}"
        exit 1
    fi

    echo -e "${GREEN}MariaDB数据库安装初始化完成${NC}"
}

# ========================== 核心功能函数 ==========================
# 安装PowerDNS主节点
install_pdns_master() {
    echo -e "${BLUE}===== 开始安装PowerDNS主节点 =====${NC}"

    # 前置环境准备
    check_root
    check_os
    handle_port_53
    install_deps
    install_mariadb

    # 添加PowerDNS官方源（最新稳定版4.9）
    echo -e "${BLUE}正在添加PowerDNS官方软件源${NC}"
    if [[ "$OS" == "debian" ]]; then
        wget -qO - https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor > /usr/share/keyrings/pdns-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/pdns-archive-keyring.gpg] http://repo.powerdns.com/debian ${VERSION_CODENAME}-auth-49 main" > /etc/apt/sources.list.d/pdns.list
        echo -e "Package: pdns-*\nPin: origin repo.powerdns.com\nPin-Priority: 600" > /etc/apt/preferences.d/pdns
    elif [[ "$OS" == "ubuntu" ]]; then
        wget -qO - https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor > /usr/share/keyrings/pdns-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/pdns-archive-keyring.gpg] http://repo.powerdns.com/ubuntu ${VERSION_CODENAME}-auth-49 main" > /etc/apt/sources.list.d/pdns.list
        echo -e "Package: pdns-*\nPin: origin repo.powerdns.com\nPin-Priority: 600" > /etc/apt/preferences.d/pdns
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        rpm --import https://repo.powerdns.com/FD380FBB-pub.asc
        if [[ "$VERSION_ID" =~ ^8 ]]; then
            REPO_URL="https://repo.powerdns.com/el/8/auth-49/x86_64/"
        elif [[ "$VERSION_ID" =~ ^9 ]]; then
            REPO_URL="https://repo.powerdns.com/el/9/auth-49/x86_64/"
        else
            echo -e "${RED}错误：不支持的RHEL版本 $VERSION_ID${NC}"
            exit 1
        fi
        echo -e "[powerdns-auth]\nname=PowerDNS Authoritative Server\nbaseurl=$REPO_URL\nenabled=1\ngpgcheck=1\ngpgkey=https://repo.powerdns.com/FD380FBB-pub.asc" > /etc/yum.repos.d/powerdns-auth.repo
        $PKG_INSTALL epel-release -y
    fi

    # 更新源并安装PowerDNS
    $PKG_UPDATE
    echo -e "${BLUE}正在安装PowerDNS服务与MySQL后端${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        PDNS_PKGS=("pdns-server" "pdns-backend-mysql")
    else
        PDNS_PKGS=("pdns" "pdns-backend-mysql")
    fi

    if ! $PKG_INSTALL "${PDNS_PKGS[@]}"; then
        echo -e "${RED}错误：PowerDNS安装失败${NC}"
        exit 1
    fi

    # 导入PowerDNS数据库表结构
    echo -e "${BLUE}正在导入PowerDNS数据库表结构${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        SCHEMA_FILE="/usr/share/doc/pdns-backend-mysql/schema.mysql.sql.gz"
        zcat "$SCHEMA_FILE" | mysql -u root -p"$DB_ROOT_PASS" "$DB_PDNS_NAME"
    else
        SCHEMA_FILE="/usr/share/doc/pdns/schema.mysql.sql"
        cat "$SCHEMA_FILE" | mysql -u root -p"$DB_ROOT_PASS" "$DB_PDNS_NAME"
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：数据库表结构导入失败${NC}"
        exit 1
    fi

    # 主节点配置交互
    read -p "请输入允许的从节点IP/IP段（多个用逗号分隔，如192.168.1.10,10.0.0.0/24）：" ALLOW_AXFR_IPS
    if [ -z "$ALLOW_AXFR_IPS" ]; then
        ALLOW_AXFR_IPS="127.0.0.1"
        echo -e "${YELLOW}未输入从节点IP，默认仅允许本地AXFR传输${NC}"
    fi

    # 生成PowerDNS主配置文件
    echo -e "${BLUE}正在生成PowerDNS主节点配置${NC}"
    [ -f /etc/powerdns/pdns.conf ] && cp /etc/powerdns/pdns.conf /etc/powerdns/pdns.conf.bak.$(date +%Y%m%d%H%M%S)

    cat > /etc/powerdns/pdns.conf << EOF
# PowerDNS 主节点核心配置
setuid=pdns
setgid=pdns
launch=gmysql
gmysql-host=localhost
gmysql-user=$DB_PDNS_USER
gmysql-password=$DB_PDNS_PASS
gmysql-dbname=$DB_PDNS_NAME
gmysql-dnssec=yes

# 主节点区域传输配置
master=yes
disable-axfr=no
allow-axfr-ips=$ALLOW_AXFR_IPS
also-notify=$ALLOW_AXFR_IPS
slave-cycle-interval=60

# API与WebServer配置
webserver=yes
webserver-address=0.0.0.0
webserver-port=$PDNS_WEBSERVER_PORT
webserver-allow-from=$PDNS_ALLOW_FROM
api=yes
api-key=$PDNS_API_KEY
api-readonly=no

# 性能与日志配置
local-address=0.0.0.0
local-ipv6=::
query-cache-ttl=60
negquery-cache-ttl=60
cache-ttl=60
log-dns-details=no
log-dns-queries=no
loglevel=3
resolver-timeout=10
EOF

    # 权限修复
    chown -R pdns:pdns /etc/powerdns
    chmod 640 /etc/powerdns/pdns.conf

    # 启动服务并设置开机自启
    echo -e "${BLUE}正在启动PowerDNS服务${NC}"
    systemctl daemon-reload
    systemctl enable --now pdns

    if ! systemctl is-active --quiet pdns; then
        echo -e "${RED}错误：PowerDNS服务启动失败，请执行 journalctl -u pdns -f 查看日志${NC}"
        exit 1
    fi

    # 配置防火墙
    configure_firewall

    # 输出安装结果
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}===================================== 主节点安装完成 =====================================${NC}"
    echo -e "${BLUE}服务器IP：$SERVER_IP${NC}"
    echo -e "${BLUE}PowerDNS API地址：http://$SERVER_IP:$PDNS_WEBSERVER_PORT${NC}"
    echo -e "${BLUE}PowerDNS API Key：$PDNS_API_KEY${NC}"
    echo -e "${BLUE}数据库root密码：$DB_ROOT_PASS${NC}"
    echo -e "${BLUE}PowerDNS数据库：库名 $DB_PDNS_NAME，用户名 $DB_PDNS_USER，密码 $DB_PDNS_PASS${NC}"
    echo -e "${BLUE}允许的从节点IP：$ALLOW_AXFR_IPS${NC}"
    echo -e "${GREEN}==========================================================================================${NC}\n"
}

# 安装PowerDNS从节点
install_pdns_slave() {
    echo -e "${BLUE}===== 开始安装PowerDNS从节点 =====${NC}"

    # 前置环境准备
    check_root
    check_os
    handle_port_53
    install_deps
    install_mariadb

    # 主节点信息交互
    read -p "请输入PowerDNS主节点IP地址（必填）：" MASTER_IP
    if [ -z "$MASTER_IP" ]; then
        echo -e "${RED}错误：主节点IP地址不能为空${NC}"
        exit 1
    fi

    # 添加PowerDNS官方源
    echo -e "${BLUE}正在添加PowerDNS官方软件源${NC}"
    if [[ "$OS" == "debian" ]]; then
        wget -qO - https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor > /usr/share/keyrings/pdns-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/pdns-archive-keyring.gpg] http://repo.powerdns.com/debian ${VERSION_CODENAME}-auth-49 main" > /etc/apt/sources.list.d/pdns.list
        echo -e "Package: pdns-*\nPin: origin repo.powerdns.com\nPin-Priority: 600" > /etc/apt/preferences.d/pdns
    elif [[ "$OS" == "ubuntu" ]]; then
        wget -qO - https://repo.powerdns.com/FD380FBB-pub.asc | gpg --dearmor > /usr/share/keyrings/pdns-archive-keyring.gpg
        echo "deb [signed-by=/usr/share/keyrings/pdns-archive-keyring.gpg] http://repo.powerdns.com/ubuntu ${VERSION_CODENAME}-auth-49 main" > /etc/apt/sources.list.d/pdns.list
        echo -e "Package: pdns-*\nPin: origin repo.powerdns.com\nPin-Priority: 600" > /etc/apt/preferences.d/pdns
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        rpm --import https://repo.powerdns.com/FD380FBB-pub.asc
        if [[ "$VERSION_ID" =~ ^8 ]]; then
            REPO_URL="https://repo.powerdns.com/el/8/auth-49/x86_64/"
        elif [[ "$VERSION_ID" =~ ^9 ]]; then
            REPO_URL="https://repo.powerdns.com/el/9/auth-49/x86_64/"
        else
            echo -e "${RED}错误：不支持的RHEL版本 $VERSION_ID${NC}"
            exit 1
        fi
        echo -e "[powerdns-auth]\nname=PowerDNS Authoritative Server\nbaseurl=$REPO_URL\nenabled=1\ngpgcheck=1\ngpgkey=https://repo.powerdns.com/FD380FBB-pub.asc" > /etc/yum.repos.d/powerdns-auth.repo
        $PKG_INSTALL epel-release -y
    fi

    # 更新源并安装PowerDNS
    $PKG_UPDATE
    echo -e "${BLUE}正在安装PowerDNS服务与MySQL后端${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        PDNS_PKGS=("pdns-server" "pdns-backend-mysql")
    else
        PDNS_PKGS=("pdns" "pdns-backend-mysql")
    fi

    if ! $PKG_INSTALL "${PDNS_PKGS[@]}"; then
        echo -e "${RED}错误：PowerDNS安装失败${NC}"
        exit 1
    fi

    # 导入PowerDNS数据库表结构
    echo -e "${BLUE}正在导入PowerDNS数据库表结构${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        SCHEMA_FILE="/usr/share/doc/pdns-backend-mysql/schema.mysql.sql.gz"
        zcat "$SCHEMA_FILE" | mysql -u root -p"$DB_ROOT_PASS" "$DB_PDNS_NAME"
    else
        SCHEMA_FILE="/usr/share/doc/pdns/schema.mysql.sql"
        cat "$SCHEMA_FILE" | mysql -u root -p"$DB_ROOT_PASS" "$DB_PDNS_NAME"
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}错误：数据库表结构导入失败${NC}"
        exit 1
    fi

    # 生成从节点配置文件
    echo -e "${BLUE}正在生成PowerDNS从节点配置${NC}"
    [ -f /etc/powerdns/pdns.conf ] && cp /etc/powerdns/pdns.conf /etc/powerdns/pdns.conf.bak.$(date +%Y%m%d%H%M%S)

    cat > /etc/powerdns/pdns.conf << EOF
# PowerDNS 从节点核心配置
setuid=pdns
setgid=pdns
launch=gmysql
gmysql-host=localhost
gmysql-user=$DB_PDNS_USER
gmysql-password=$DB_PDNS_PASS
gmysql-dbname=$DB_PDNS_NAME
gmysql-dnssec=yes

# 从节点同步配置
slave=yes
master=$MASTER_IP
allow-notify-from=$MASTER_IP
slave-cycle-interval=60

# API与WebServer配置
webserver=yes
webserver-address=0.0.0.0
webserver-port=$PDNS_WEBSERVER_PORT
webserver-allow-from=$PDNS_ALLOW_FROM
api=yes
api-key=$PDNS_API_KEY
api-readonly=no

# 性能与日志配置
local-address=0.0.0.0
local-ipv6=::
query-cache-ttl=60
negquery-cache-ttl=60
cache-ttl=60
log-dns-details=no
log-dns-queries=no
loglevel=3
resolver-timeout=10
EOF

    # 权限修复
    chown -R pdns:pdns /etc/powerdns
    chmod 640 /etc/powerdns/pdns.conf

    # 启动服务并设置开机自启
    echo -e "${BLUE}正在启动PowerDNS服务${NC}"
    systemctl daemon-reload
    systemctl enable --now pdns

    if ! systemctl is-active --quiet pdns; then
        echo -e "${RED}错误：PowerDNS服务启动失败，请执行 journalctl -u pdns -f 查看日志${NC}"
        exit 1
    fi

    # 配置防火墙
    configure_firewall

    # 输出安装结果
    SERVER_IP=$(hostname -I | awk '{print $1}')
    echo -e "\n${GREEN}===================================== 从节点安装完成 =====================================${NC}"
    echo -e "${BLUE}从节点IP：$SERVER_IP${NC}"
    echo -e "${BLUE}主节点IP：$MASTER_IP${NC}"
    echo -e "${BLUE}PowerDNS API地址：http://$SERVER_IP:$PDNS_WEBSERVER_PORT${NC}"
    echo -e "${BLUE}PowerDNS API Key：$PDNS_API_KEY${NC}"
    echo -e "${BLUE}数据库root密码：$DB_ROOT_PASS${NC}"
    echo -e "${BLUE}PowerDNS数据库：库名 $DB_PDNS_NAME，用户名 $DB_PDNS_USER，密码 $DB_PDNS_PASS${NC}"
    echo -e "${GREEN}==========================================================================================${NC}\n"
}

# 安装PowerAdmin Web管理面板
install_poweradmin() {
    echo -e "${BLUE}===== 开始安装PowerAdmin Web管理面板 =====${NC}"

    # 前置环境准备
    check_root
    check_os
    install_deps

    # 检查PowerDNS环境
    if ! command -v pdns_control &> /dev/null; then
        echo -e "${YELLOW}警告：未检测到本地PowerDNS服务，建议先安装PowerDNS主节点${NC}"
        read -p "是否继续安装PowerAdmin？(y/n)：" CONTINUE_INSTALL
        if [[ ! "$CONTINUE_INSTALL" =~ ^[Yy]$ ]]; then
            echo -e "${RED}已取消PowerAdmin安装${NC}"
            return 0
        fi
    fi

    # 安装Nginx、PHP及扩展
    echo -e "${BLUE}正在安装Nginx、PHP运行环境${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        PHP_PKGS=("php-fpm" "php-mysql" "php-curl" "php-mbstring" "php-json" "php-gd" "php-xml" "php-intl")
        if ! $PKG_INSTALL nginx "${PHP_PKGS[@]}"; then
            echo -e "${RED}错误：Nginx/PHP安装失败${NC}"
            exit 1
        fi
        # 适配PHP版本
        PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
        PHP_FPM_SERVICE="php${PHP_VERSION}-fpm"
        PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    else
        # RHEL系适配PHP版本
        if [[ "$VERSION_ID" =~ ^8 ]]; then
            dnf module enable -y php:7.4 > /dev/null 2>&1
        elif [[ "$VERSION_ID" =~ ^9 ]]; then
            dnf module enable -y php:8.1 > /dev/null 2>&1
        fi
        PHP_PKGS=("php-fpm" "php-mysqlnd" "php-curl" "php-mbstring" "php-json" "php-gd" "php-xml" "php-intl")
        if ! $PKG_INSTALL nginx "${PHP_PKGS[@]}"; then
            echo -e "${RED}错误：Nginx/PHP安装失败${NC}"
            exit 1
        fi
        PHP_FPM_SERVICE="php-fpm"
        PHP_FPM_SOCKET="/run/php-fpm/www.sock"
    fi

    # 验证PHP-FPM环境
    systemctl enable --now $PHP_FPM_SERVICE
    if [ ! -S "$PHP_FPM_SOCKET" ]; then
        echo -e "${RED}错误：PHP-FPM socket不存在，请检查PHP-FPM服务状态${NC}"
        exit 1
    fi

    # 下载PowerAdmin
    echo -e "${BLUE}正在下载PowerAdmin安装包${NC}"
    mkdir -p $POWERADMIN_WEB_ROOT
    cd $POWERADMIN_WEB_ROOT

    # 获取最新版本
    if [ "$POWERADMIN_VERSION" == "latest" ]; then
        LATEST_TAG=$(curl -s https://api.github.com/repos/poweradmin/poweradmin/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
        if [ -z "$LATEST_TAG" ]; then
            echo -e "${RED}错误：获取PowerAdmin最新版本失败，请检查网络连接${NC}"
            exit 1
        fi
        POWERADMIN_VERSION=$LATEST_TAG
        echo -e "${GREEN}检测到最新版本：$POWERADMIN_VERSION${NC}"
    fi

    # 下载并解压
    DOWNLOAD_URL="https://github.com/poweradmin/poweradmin/archive/refs/tags/${POWERADMIN_VERSION}.tar.gz"
    if ! wget -q -O poweradmin.tar.gz "$DOWNLOAD_URL"; then
        echo -e "${RED}错误：PowerAdmin安装包下载失败${NC}"
        exit 1
    fi

    tar -xzf poweradmin.tar.gz --strip-components=1
    rm -f poweradmin.tar.gz

    # 目录权限配置
    echo -e "${BLUE}正在配置目录权限${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        WEB_USER="www-data"
    else
        WEB_USER="nginx"
    fi

    chown -R $WEB_USER:$WEB_USER $POWERADMIN_WEB_ROOT
    chmod -R 755 $POWERADMIN_WEB_ROOT
    chmod -R 777 $POWERADMIN_WEB_ROOT/inc/

    # 生成Nginx配置
    echo -e "${BLUE}正在生成Nginx站点配置${NC}"
    SERVER_IP=$(hostname -I | awk '{print $1}')
    cat > $POWERADMIN_NGINX_CONF << EOF
server {
    listen 80;
    server_name $SERVER_IP;
    root $POWERADMIN_WEB_ROOT;
    index index.php index.html index.htm;

    access_log /var/log/nginx/poweradmin-access.log;
    error_log /var/log/nginx/poweradmin-error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass unix:$PHP_FPM_SOCKET;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    # 验证Nginx配置
    if ! nginx -t; then
        echo -e "${RED}错误：Nginx配置语法错误，请检查配置文件${NC}"
        exit 1
    fi

    # 启动Nginx服务
    echo -e "${BLUE}正在启动Nginx服务${NC}"
    systemctl enable --now nginx
    if ! systemctl is-active --quiet nginx; then
        echo -e "${RED}错误：Nginx服务启动失败${NC}"
        exit 1
    fi

    # SELinux适配（RHEL系）
    if [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        echo -e "${BLUE}正在配置SELinux规则${NC}"
        setsebool -P httpd_can_network_connect on
        setsebool -P httpd_can_network_connect_db on
        chcon -R -t httpd_sys_content_t $POWERADMIN_WEB_ROOT
        chcon -R -t httpd_sys_rw_content_t $POWERADMIN_WEB_ROOT/inc/
        echo -e "${GREEN}SELinux规则配置完成${NC}"
    fi

    # 配置防火墙
    configure_firewall

    # 输出安装结果
    echo -e "\n${GREEN}===================================== PowerAdmin安装完成 =====================================${NC}"
    echo -e "${BLUE}面板访问地址：http://$SERVER_IP${NC}"
    echo -e "${BLUE}安装向导所需核心信息：${NC}"
    echo -e "  数据库类型：MySQL"
    echo -e "  数据库主机：localhost"
    echo -e "  数据库端口：3306"
    echo -e "  PowerDNS数据库名：$DB_PDNS_NAME"
    echo -e "  PowerDNS数据库用户名：$DB_PDNS_USER"
    echo -e "  PowerDNS数据库密码：$DB_PDNS_PASS"
    echo -e "  PowerDNS API地址：http://127.0.0.1:$PDNS_WEBSERVER_PORT"
    echo -e "  PowerDNS API Key：$PDNS_API_KEY"
    echo -e "${YELLOW}安全提示：完成安装向导后，请立即删除 $POWERADMIN_WEB_ROOT/install 目录！${NC}"
    echo -e "${GREEN}================================================================================================${NC}\n"
}

# PowerDNS服务管理
manage_pdns_service() {
    while true; do
        echo -e "\n${BLUE}===================================== PowerDNS服务管理 =====================================${NC}"
        echo "1. 启动PowerDNS服务"
        echo "2. 停止PowerDNS服务"
        echo "3. 重启PowerDNS服务"
        echo "4. 查看服务运行状态"
        echo "5. 启用开机自启"
        echo "6. 禁用开机自启"
        echo "7. 查看实时运行日志"
        echo "0. 返回主菜单"
        echo -e "${BLUE}=============================================================================================${NC}\n"
        read -p "请选择操作序号：" SERVICE_OPTION

        case $SERVICE_OPTION in
            1)
                echo -e "${BLUE}正在启动PowerDNS服务${NC}"
                systemctl start pdns
                if systemctl is-active --quiet pdns; then
                    echo -e "${GREEN}PowerDNS服务启动成功${NC}"
                else
                    echo -e "${RED}PowerDNS服务启动失败，请检查日志${NC}"
                fi
                ;;
            2)
                echo -e "${BLUE}正在停止PowerDNS服务${NC}"
                systemctl stop pdns
                if ! systemctl is-active --quiet pdns; then
                    echo -e "${GREEN}PowerDNS服务已停止${NC}"
                else
                    echo -e "${RED}PowerDNS服务停止失败${NC}"
                fi
                ;;
            3)
                echo -e "${BLUE}正在重启PowerDNS服务${NC}"
                systemctl restart pdns
                if systemctl is-active --quiet pdns; then
                    echo -e "${GREEN}PowerDNS服务重启成功${NC}"
                else
                    echo -e "${RED}PowerDNS服务重启失败，请检查日志${NC}"
                fi
                ;;
            4)
                echo -e "${BLUE}PowerDNS服务运行状态：${NC}"
                systemctl status pdns --no-pager -l
                ;;
            5)
                systemctl enable pdns
                echo -e "${GREEN}PowerDNS开机自启已启用${NC}"
                ;;
            6)
                systemctl disable pdns
                echo -e "${GREEN}PowerDNS开机自启已禁用${NC}"
                ;;
            7)
                echo -e "${BLUE}PowerDNS实时日志（按Ctrl+C退出）：${NC}"
                journalctl -u pdns -f
                ;;
            0)
                break
                ;;
            *)
                echo -e "${RED}无效的选项，请重新输入${NC}"
                ;;
        esac
        read -p "按回车键继续..."
    done
}

# 查看PowerDNS API密钥
show_api_key() {
    echo -e "${BLUE}正在获取PowerDNS API密钥${NC}"

    if [ ! -f /etc/powerdns/pdns.conf ]; then
        echo -e "${RED}错误：未找到PowerDNS配置文件，请先安装PowerDNS${NC}"
        return 1
    fi

    # 提取配置信息
    API_KEY=$(grep -oP '^api-key=\K.*' /etc/powerdns/pdns.conf)
    WEBSERVER_PORT=$(grep -oP '^webserver-port=\K.*' /etc/powerdns/pdns.conf)
    SERVER_IP=$(hostname -I | awk '{print $1}')

    if [ -z "$API_KEY" ]; then
        echo -e "${RED}错误：未在配置文件中找到API Key，请检查PowerDNS配置${NC}"
        return 1
    fi

    echo -e "\n${GREEN}===================================== PowerDNS API信息 =====================================${NC}"
    echo -e "${BLUE}API访问地址：http://$SERVER_IP:$WEBSERVER_PORT${NC}"
    echo -e "${BLUE}API Key：$API_KEY${NC}"
    echo -e "${GREEN}=============================================================================================${NC}\n"
}

# 彻底卸载PowerDNS与PowerAdmin
uninstall_all() {
    echo -e "\n${RED}===================================== 高危操作警告 =====================================${NC}"
    echo -e "${RED}此操作将彻底卸载PowerDNS、PowerAdmin、MariaDB，删除所有配置文件和数据库数据！${NC}"
    echo -e "${RED}操作不可逆，请确认已备份所有重要数据！${NC}"
    echo -e "${RED}========================================================================================${NC}\n"
    read -p "请输入大写的 YES 确认卸载（输入其他内容将取消）：" UNINSTALL_CONFIRM

    if [ "$UNINSTALL_CONFIRM" != "YES" ]; then
        echo -e "${GREEN}已取消卸载操作${NC}"
        return 0
    fi

    check_os
    echo -e "${BLUE}正在执行卸载操作，请稍候...${NC}"

    # 停止并禁用所有相关服务
    SERVICES=("pdns" "nginx" "php*-fpm" "mariadb" "mysql")
    for service in "${SERVICES[@]}"; do
        systemctl stop $service > /dev/null 2>&1
        systemctl disable $service > /dev/null 2>&1
    done

    # 卸载软件包
    echo -e "${BLUE}正在卸载相关软件包${NC}"
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        UNINSTALL_PKGS=("pdns-server" "pdns-backend-mysql" "mariadb-server" "mariadb-client" "nginx" "php*-fpm" "php-*")
    else
        UNINSTALL_PKGS=("pdns" "pdns-backend-mysql" "mariadb-server" "mariadb" "nginx" "php-fpm" "php-*")
    fi
    $PKG_REMOVE "${UNINSTALL_PKGS[@]}" > /dev/null 2>&1
    $PKG_MANAGER autoremove -y --purge > /dev/null 2>&1

    # 删除配置文件与数据
    echo -e "${BLUE}正在清理配置文件与残留数据${NC}"
    rm -rf /etc/powerdns
    rm -rf /var/lib/powerdns
    rm -rf $POWERADMIN_WEB_ROOT
    rm -f $POWERADMIN_NGINX_CONF
    rm -rf /var/lib/mysql
    rm -rf /etc/mysql /etc/my.cnf.d
    rm -f /etc/apt/sources.list.d/pdns.list /etc/apt/preferences.d/pdns /usr/share/keyrings/pdns-archive-keyring.gpg
    rm -f /etc/yum.repos.d/powerdns-auth.repo

    # 恢复systemd-resolved配置
    if [ "$DISABLE_SYSTEMD_RESOLVED" == "yes" ]; then
        sed -i 's/DNSStubListener=no/#DNSStubListener=yes/' /etc/systemd/resolved.conf
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        systemctl restart systemd-resolved > /dev/null 2>&1
    fi

    # 清理防火墙规则
    if [ "$CONFIGURE_FIREWALL" == "yes" ]; then
        echo -e "${BLUE}正在清理防火墙规则${NC}"
        PORTS=("53/tcp" "53/udp" "80/tcp" "${PDNS_WEBSERVER_PORT}/tcp")
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
            if command -v ufw &> /dev/null && ufw status | grep -q "active"; then
                for port in "${PORTS[@]}"; do
                    ufw delete allow "$port" > /dev/null 2>&1
                done
                ufw reload > /dev/null 2>&1
            fi
        elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
            if systemctl is-active --quiet firewalld; then
                for port in "${PORTS[@]}"; do
                    firewall-cmd --permanent --remove-port="$port" > /dev/null 2>&1
                done
                firewall-cmd --reload > /dev/null 2>&1
            fi
        fi
    fi

    echo -e "\n${GREEN}===================================== 卸载完成 =====================================${NC}"
    echo -e "${GREEN}PowerDNS、PowerAdmin、MariaDB已全部彻底卸载${NC}"
    echo -e "${GREEN}====================================================================================${NC}\n"
}

# ========================== 主菜单入口 ==========================
# 启动前检查root权限
check_root

# 主菜单循环
while true; do
    clear
    echo -e "\n${GREEN}===================================== PowerDNS 全功能管理脚本 =====================================${NC}"
    echo "1. 安装PowerDNS主节点"
    echo "2. 安装PowerDNS从节点（多节点集群）"
    echo "3. 安装PowerAdmin Web管理面板"
    echo "4. PowerDNS服务管理（启动/停止/重启/自启/日志）"
    echo "5. 查看PowerDNS API Key"
    echo "6. 彻底卸载PowerDNS与PowerAdmin"
    echo "0. 退出脚本"
    echo -e "${GREEN}====================================================================================================${NC}\n"
    read -p "请选择要执行的操作序号：" MAIN_OPTION

    case $MAIN_OPTION in
        1)
            install_pdns_master
            ;;
        2)
            install_pdns_slave
            ;;
        3)
            install_poweradmin
            ;;
        4)
            manage_pdns_service
            ;;
        5)
            show_api_key
            ;;
        6)
            uninstall_all
            ;;
        0)
            echo -e "${GREEN}感谢使用，脚本已退出${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选项，请重新输入${NC}"
            ;;
    esac
    read -p "按回车键返回主菜单..."
done
