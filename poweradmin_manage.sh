#!/bin/bash
set -o pipefail

# ===================== 颜色输出函数 =====================
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

# ===================== 全局变量与系统检测 =====================
OS=""
VERSION_ID=""
PM=""
PM_UPDATE=""
PM_INSTALL=""
PM_REMOVE=""
PM_AUTOREMOVE=""
SERVICE_MGR="systemctl"
WEB_SERVICE="nginx"
PHP_FPM_SERVICE=""
PDNS_CONF=""
PDNS_CONF_DIR=""

# 系统发行版检测
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
        VERSION_ID=$VERSION_ID
    else
        error "无法检测系统发行版，脚本仅支持Debian/Ubuntu和RHEL/CentOS/Rocky/AlmaLinux系统"
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
        # 预定义PHP服务名，后续安装后更新
        PHP_FPM_SERVICE="php-fpm"
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
        PHP_FPM_SERVICE="php-fpm"
    else
        error "不支持的系统发行版 $OS，脚本仅支持Debian/Ubuntu和RHEL/CentOS/Rocky/AlmaLinux系统"
        exit 1
    fi
}

# ===================== 工具函数 =====================
# 生成随机字符串
generate_random() {
    local length=${1:-16}
    tr -dc A-Za-z0-9 < /dev/urandom | head -c $length
}

# 端口占用检查
check_port() {
    local port=$1
    local proto=$2
    if ss -${proto}lnp | grep -q ":$port "; then
        return 0
    else
        return 1
    fi
}

# 修复systemd-resolved占用53端口问题
fix_systemd_resolved() {
    if check_port 53 udp && ss -ulnp | grep :53 | grep -q systemd-resolved; then
        warn "检测到systemd-resolved占用53端口，正在释放端口..."
        sed -i 's/#DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
        sed -i 's/DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
        systemctl daemon-reload
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        info "已释放53端口，systemd-resolved已配置为不占用53端口"
    fi
}

# ===================== 核心功能函数 =====================
# 1. 安装主节点（PowerDNS+MariaDB+PowerAdmin+API）
install_master() {
    info "开始安装 PowerDNS 主节点（含PowerAdmin、数据库、API）"
    detect_os
    fix_systemd_resolved

    # 更新系统包
    info "正在更新系统包..."
    $PM_UPDATE
    if [ $? -ne 0 ]; then
        error "系统包更新失败，请检查网络或源配置"
        return 1
    fi

    # 安装基础依赖
    info "正在安装基础依赖..."
    $PM_INSTALL curl wget gnupg2 ca-certificates
    if [ $? -ne 0 ]; then
        error "基础依赖安装失败"
        return 1
    fi

    # 安装MariaDB数据库
    info "正在安装 MariaDB 数据库..."
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
    success "MariaDB 安装并启动成功"

    # 安装Nginx和PHP环境
    info "正在安装 Nginx 和 PHP 环境..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        $PM_INSTALL nginx php-fpm php-mysql php-curl php-mbstring php-xml php-gd php-intl
        # 获取实际PHP版本
        PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')
        PHP_FPM_SERVICE="php$PHP_VERSION-fpm"
    else
        $PM_INSTALL nginx php-fpm php-mysqlnd php-curl php-mbstring php-xml php-gd php-intl
        PHP_FPM_SERVICE="php-fpm"
    fi
    if [ $? -ne 0 ]; then
        error "Nginx/PHP 安装失败"
        return 1
    fi
    # 启动PHP-FPM
    systemctl start $PHP_FPM_SERVICE
    systemctl enable $PHP_FPM_SERVICE
    if ! systemctl is-active --quiet $PHP_FPM_SERVICE; then
        error "PHP-FPM 服务启动失败"
        return 1
    fi
    success "Nginx/PHP 安装并启动成功"

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

    # 配置变量定义
    DB_ROOT_PASS=$(generate_random 16)
    PDNS_DB_NAME="powerdns"
    PDNS_DB_USER="powerdns"
    PDNS_DB_PASS=$(generate_random 16)
    PDNS_API_KEY=$(generate_random 32)
    PDNS_API_PORT=8081
    PDNS_WEB_ALLOW_FROM="0.0.0.0/0"
    POWERADMIN_VERSION="3.8.0"
    POWERADMIN_WEB_ROOT="/var/www/poweradmin"
    POWERADMIN_ADMIN_USER="admin"
    POWERADMIN_ADMIN_PASS=$(generate_random 16)

    # 初始化数据库
    info "正在初始化数据库..."
    # 设置root密码
    mysqladmin -u root password "$DB_ROOT_PASS"
    if [ $? -ne 0 ]; then
        warn "MariaDB root密码已存在，尝试重置并执行初始化..."
        mysql -u root << EOF
SET PASSWORD FOR 'root'@'localhost' = PASSWORD('$DB_ROOT_PASS');
FLUSH PRIVILEGES;
EOF
        if [ $? -ne 0 ]; then
            error "MariaDB 初始化失败，无法设置root密码，请手动处理"
            return 1
        fi
    fi

    # 安全设置+创建PowerDNS数据库
    mysql -u root -p"$DB_ROOT_PASS" << EOF
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
CREATE DATABASE $PDNS_DB_NAME CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER '$PDNS_DB_USER'@'localhost' IDENTIFIED BY '$PDNS_DB_PASS';
GRANT ALL PRIVILEGES ON $PDNS_DB_NAME.* TO '$PDNS_DB_USER'@'localhost';
CREATE USER '$PDNS_DB_USER'@'%' IDENTIFIED BY '$PDNS_DB_PASS';
GRANT ALL PRIVILEGES ON $PDNS_DB_NAME.* TO '$PDNS_DB_USER'@'%';
FLUSH PRIVILEGES;
EOF
    if [ $? -ne 0 ]; then
        error "数据库初始化失败，无法创建PowerDNS数据库和用户"
        return 1
    fi
    success "数据库初始化完成"

    # 导入PowerDNS表结构
    info "正在导入 PowerDNS 数据库表结构..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        SCHEMA_FILE="/usr/share/doc/pdns-backend-mysql/schema.mysql.sql.gz"
        if [ ! -f $SCHEMA_FILE ]; then
            error "PowerDNS 表结构文件不存在 $SCHEMA_FILE"
            return 1
        fi
        zcat $SCHEMA_FILE | mysql -u $PDNS_DB_USER -p$PDNS_DB_PASS $PDNS_DB_NAME
    else
        SCHEMA_FILE="/usr/share/doc/pdns/schema.mysql.sql"
        if [ ! -f $SCHEMA_FILE ]; then
            error "PowerDNS 表结构文件不存在 $SCHEMA_FILE"
            return 1
        fi
        mysql -u $PDNS_DB_USER -p$PDNS_DB_PASS $PDNS_DB_NAME < $SCHEMA_FILE
    fi
    if [ $? -ne 0 ]; then
        error "PowerDNS 表结构导入失败"
        return 1
    fi
    success "PowerDNS 表结构导入完成"

    # 配置PowerDNS
    info "正在配置 PowerDNS..."
    cp $PDNS_CONF $PDNS_CONF.bak.$(date +%Y%m%d%H%M%S)
    cat > $PDNS_CONF << EOF
# PowerDNS 主节点配置文件
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

# MySQL后端配置
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=$PDNS_DB_NAME
gmysql-user=$PDNS_DB_USER
gmysql-password=$PDNS_DB_PASS
gmysql-dnssec=yes

# API配置
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
    # 删除Debian默认的bind后端冲突配置
    if [ -f $PDNS_CONF_DIR/bind.conf ]; then
        rm -f $PDNS_CONF_DIR/bind.conf
        info "已删除默认的bind后端配置，避免启动冲突"
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

    # 安装PowerAdmin管理面板
    info "正在安装 PowerAdmin 管理面板..."
    wget -O /tmp/poweradmin.tar.gz https://github.com/poweradmin/poweradmin/archive/refs/tags/v$POWERADMIN_VERSION.tar.gz
    if [ $? -ne 0 ]; then
        error "PowerAdmin 源码下载失败，请检查网络连接"
        return 1
    fi
    # 解压部署
    tar -zxf /tmp/poweradmin.tar.gz -C /tmp
    if [ ! -d /tmp/poweradmin-$POWERADMIN_VERSION ]; then
        error "PowerAdmin 解压失败"
        return 1
    fi
    rm -rf $POWERADMIN_WEB_ROOT
    mv /tmp/poweradmin-$POWERADMIN_VERSION $POWERADMIN_WEB_ROOT
    # 设置权限
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        chown -R www-data:www-data $POWERADMIN_WEB_ROOT
    else
        chown -R nginx:nginx $POWERADMIN_WEB_ROOT
    fi
    chmod -R 755 $POWERADMIN_WEB_ROOT
    success "PowerAdmin 源码部署完成"

    # 导入PowerAdmin表结构
    info "正在导入 PowerAdmin 数据库表结构..."
    POWERADMIN_SQL="$POWERADMIN_WEB_ROOT/install/poweradmin-mysql-db-structure.sql"
    if [ ! -f $POWERADMIN_SQL ]; then
        error "PowerAdmin 表结构文件不存在 $POWERADMIN_SQL"
        return 1
    fi
    mysql -u $PDNS_DB_USER -p$PDNS_DB_PASS $PDNS_DB_NAME < $POWERADMIN_SQL
    if [ $? -ne 0 ]; then
        error "PowerAdmin 表结构导入失败"
        return 1
    fi
    success "PowerAdmin 表结构导入完成"

    # 生成PowerAdmin配置文件
    info "正在生成 PowerAdmin 配置文件..."
    # 生成管理员密码哈希
    POWERADMIN_ADMIN_PASS_HASH=$(php -r "echo password_hash('$POWERADMIN_ADMIN_PASS', PASSWORD_DEFAULT);")
    # 更新管理员密码
    mysql -u $PDNS_DB_USER -p$PDNS_DB_PASS $PDNS_DB_NAME << EOF
UPDATE users SET password='$POWERADMIN_ADMIN_PASS_HASH' WHERE username='$POWERADMIN_ADMIN_USER';
EOF
    # 生成配置文件
    cat > $POWERADMIN_WEB_ROOT/inc/config.inc.php << EOF
<?php
\$db_host = '127.0.0.1';
\$db_user = '$PDNS_DB_USER';
\$db_pass = '$PDNS_DB_PASS';
\$db_name = '$PDNS_DB_NAME';
\$db_port = '3306';
\$db_charset = 'utf8mb4';

\$session_key = '$(generate_random 32)';
\$iface_lang = 'en_EN';
\$dns_hostmaster = 'hostmaster@example.com';
\$dns_ns1 = 'ns1.example.com';
\$dns_ns2 = 'ns2.example.com';

\$pdns_api_url = 'http://127.0.0.1:$PDNS_API_PORT';
\$pdns_api_key = '$PDNS_API_KEY';
\$pdns_api_verify_ssl = false;
?>
EOF
    # 配置文件权限
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        chown www-data:www-data $POWERADMIN_WEB_ROOT/inc/config.inc.php
    else
        chown nginx:nginx $POWERADMIN_WEB_ROOT/inc/config.inc.php
    fi
    chmod 640 $POWERADMIN_WEB_ROOT/inc/config.inc.php
    success "PowerAdmin 配置文件生成完成"

    # 配置Nginx虚拟主机
    info "正在配置 Nginx 虚拟主机..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        NGINX_CONF_PATH="/etc/nginx/sites-available/poweradmin.conf"
        NGINX_ENABLED_PATH="/etc/nginx/sites-enabled/poweradmin.conf"
        cat > $NGINX_CONF_PATH << EOF
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
        ln -sf $NGINX_CONF_PATH $NGINX_ENABLED_PATH
    else
        NGINX_CONF_PATH="/etc/nginx/conf.d/poweradmin.conf"
        cat > $NGINX_CONF_PATH << EOF
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
    # 测试并重启Nginx
    nginx -t
    if [ $? -ne 0 ]; then
        error "Nginx 配置文件有误，请检查配置"
        return 1
    fi
    systemctl restart nginx
    systemctl enable nginx
    if ! systemctl is-active --quiet nginx; then
        error "Nginx 服务重启失败"
        return 1
    fi
    success "Nginx 虚拟主机配置完成"

    # 配置SELinux（RHEL系）
    if [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]]; then
        info "正在配置 SELinux 规则..."
        setsebool -P httpd_can_network_connect on
        setsebool -P httpd_can_network_connect_db on
        chcon -R -t httpd_sys_content_t $POWERADMIN_WEB_ROOT
        chcon -R -t httpd_sys_rw_content_t $POWERADMIN_WEB_ROOT/inc
        if [ $? -ne 0 ]; then
            warn "SELinux 规则配置失败，请手动检查"
        else
            success "SELinux 规则配置完成"
        fi
    fi

    # 配置防火墙
    info "正在配置防火墙规则..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
        ufw allow 53/tcp
        ufw allow 53/udp
        ufw allow 80/tcp
        ufw allow $PDNS_API_PORT/tcp
        ufw reload
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=53/tcp
        firewall-cmd --permanent --add-port=53/udp
        firewall-cmd --permanent --add-port=80/tcp
        firewall-cmd --permanent --add-port=$PDNS_API_PORT/tcp
        firewall-cmd --reload
    fi
    success "防火墙规则配置完成"

    # 获取服务器IP
    SERVER_IP=$(hostname -I | awk '{print $1}')

    # 输出安装结果
    echo ""
    success "================================= 主节点安装完成 =================================="
    info "【数据库信息】"
    info "MariaDB root 密码: $DB_ROOT_PASS"
    info "PowerDNS 数据库名: $PDNS_DB_NAME"
    info "PowerDNS 数据库用户名: $PDNS_DB_USER"
    info "PowerDNS 数据库密码: $PDNS_DB_PASS"
    echo ""
    info "【PowerDNS API 信息】"
    info "API 地址: http://$SERVER_IP:$PDNS_API_PORT"
    info "API Key: $PDNS_API_KEY"
    echo ""
    info "【PowerAdmin 管理面板】"
    info "访问地址: http://$SERVER_IP"
    info "管理员账号: $POWERADMIN_ADMIN_USER"
    info "管理员密码: $POWERADMIN_ADMIN_PASS"
    echo ""
    warn "【重要提示】"
    warn "1. 请妥善保存以上账号密码信息，丢失无法找回"
    warn "2. 请及时修改PowerAdmin的默认NS配置和hostmaster邮箱"
    warn "3. 生产环境请限制API和数据库的访问IP，提高安全性"
    warn "4. 如需配置HTTPS，请自行修改Nginx配置添加SSL证书"
    success "==================================================================================="
    echo ""
}

# 2. 安装从节点（多节点扩展）
install_slave() {
    info "开始安装 PowerDNS 从节点（多节点扩展）"
    detect_os
    fix_systemd_resolved

    # 更新系统包
    info "正在更新系统包..."
    $PM_UPDATE
    if [ $? -ne 0 ]; then
        error "系统包更新失败，请检查网络或源配置"
        return 1
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
    echo -e "\033[33m请输入主节点数据库配置信息：\033[0m"
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
    if ! mysql -h $MASTER_DB_HOST -P $MASTER_DB_PORT -u $MASTER_DB_USER -p"$MASTER_DB_PASS" -e "USE $MASTER_DB_NAME;" &> /dev/null; then
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

    # 配置PowerDNS
    info "正在配置 PowerDNS 从节点..."
    cp $PDNS_CONF $PDNS_CONF.bak.$(date +%Y%m%d%H%M%S)
    cat > $PDNS_CONF << EOF
# PowerDNS 从节点配置文件
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

# MySQL后端配置（连接主节点数据库）
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
        cat >> $PDNS_CONF << EOF

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
    if [ -f $PDNS_CONF_DIR/bind.conf ]; then
        rm -f $PDNS_CONF_DIR/bind.conf
        info "已删除默认的bind后端配置，避免启动冲突"
    fi
    success "PowerDNS 从节点配置完成"

    # 配置防火墙
    info "正在配置防火墙规则..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
        ufw allow 53/tcp
        ufw allow 53/udp
        if [ "$ENABLE_API" = "y" ]; then
            ufw allow $PDNS_API_PORT/tcp
        fi
        ufw reload
    elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
        firewall-cmd --permanent --add-port=53/tcp
        firewall-cmd --permanent --add-port=53/udp
        if [ "$ENABLE_API" = "y" ]; then
            firewall-cmd --permanent --add-port=$PDNS_API_PORT/tcp
        fi
        firewall-cmd --reload
    fi
    success "防火墙规则配置完成"

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
    echo ""
    success "================================= 从节点安装完成 =================================="
    info "PowerDNS 服务已启动，监听53端口（TCP/UDP）"
    info "节点IP: $SERVER_IP"
    if [ "$ENABLE_API" = "y" ]; then
        info "从节点API地址: http://$SERVER_IP:$PDNS_API_PORT"
        info "从节点API Key: $PDNS_API_KEY"
    fi
    info "主数据库连接: $MASTER_DB_HOST:$MASTER_DB_PORT"
    warn "请确保主节点数据库可被当前节点访问，防火墙已放行相关端口"
    success "==================================================================================="
    echo ""
}

# 3. 卸载所有组件
uninstall_all() {
    warn "警告：此操作将彻底卸载 PowerDNS、PowerAdmin、MariaDB、Nginx、PHP 所有相关组件，删除所有配置文件和数据库数据，数据不可逆！"
    read -p "请输入 YES 确认继续卸载: " CONFIRM
    if [ "$CONFIRM" != "YES" ]; then
        info "已取消卸载操作"
        return 0
    fi

    detect_os

    # 停止并禁用服务
    info "正在停止所有相关服务..."
    systemctl stop pdns mariadb nginx $PHP_FPM_SERVICE &> /dev/null
    systemctl disable pdns mariadb nginx $PHP_FPM_SERVICE &> /dev/null

    # 卸载软件包
    info "正在卸载相关软件包..."
    if [[ "$OS" =~ ^(debian|ubuntu)$ ]]; then
        $PM_REMOVE pdns-server pdns-backend-mysql mariadb-server mariadb-client nginx php*
    else
        $PM_REMOVE pdns pdns-backend-mysql mariadb-server mariadb nginx php*
    fi
    $PM_AUTOREMOVE

    # 删除配置和数据
    info "正在删除残留配置文件和数据..."
    rm -rf /etc/powerdns /etc/pdns
    rm -rf /var/lib/mysql
    rm -rf /var/www/poweradmin
    rm -f /etc/nginx/sites-available/poweradmin.conf /etc/nginx/sites-enabled/poweradmin.conf
    rm -f /etc/nginx/conf.d/poweradmin.conf
    rm -f /etc/apt/sources.list.d/powerdns-auth.list
    rm -f /etc/yum.repos.d/powerdns-auth.repo
    rm -rf /usr/share/keyrings/powerdns-archive-keyring.gpg
    rm -rf /tmp/poweradmin*

    # 恢复systemd-resolved配置
    read -p "是否恢复 systemd-resolved 的53端口占用配置? [y/N]: " RESTORE_RESOLVED
    RESTORE_RESOLVED=${RESTORE_RESOLVED,,}
    if [ "$RESTORE_RESOLVED" = "y" ]; then
        sed -i 's/DNSStubListener=no/DNSStubListener=yes/g' /etc/systemd/resolved.conf
        systemctl daemon-reload
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
        info "已恢复 systemd-resolved 配置"
    fi

    # 清理防火墙规则
    read -p "是否清理防火墙相关端口规则(53/80/8081)? [y/N]: " CLEAN_FIREWALL
    CLEAN_FIREWALL=${CLEAN_FIREWALL,,}
    if [ "$CLEAN_FIREWALL" = "y" ]; then
        if [[ "$OS" =~ ^(debian|ubuntu)$ ]] && command -v ufw &> /dev/null; then
            ufw delete allow 53/tcp &> /dev/null
            ufw delete allow 53/udp &> /dev/null
            ufw delete allow 80/tcp &> /dev/null
            ufw delete allow 8081/tcp &> /dev/null
            ufw reload
        elif [[ "$OS" =~ ^(rhel|centos|rocky|almalinux|ol)$ ]] && command -v firewall-cmd &> /dev/null; then
            firewall-cmd --permanent --remove-port=53/tcp &> /dev/null
            firewall-cmd --permanent --remove-port=53/udp &> /dev/null
            firewall-cmd --permanent --remove-port=80/tcp &> /dev/null
            firewall-cmd --permanent --remove-port=8081/tcp &> /dev/null
            firewall-cmd --reload
        fi
        info "已清理防火墙规则"
    fi

    # 完成提示
    success "================================= 卸载完成 =================================="
    info "所有相关组件已彻底卸载，如需清理残留日志，请手动删除 /var/log/ 下的相关日志文件"
    warn "建议重启系统以清理所有残留进程和配置"
    echo ""
}

# 4. 启动所有服务
start_services() {
    detect_os
    info "正在启动所有相关服务..."
    systemctl start pdns mariadb nginx $PHP_FPM_SERVICE
    if [ $? -eq 0 ]; then
        success "所有服务启动成功"
    else
        error "部分服务启动失败，请查看日志"
    fi
    show_status
}

# 5. 停止所有服务
stop_services() {
    detect_os
    info "正在停止所有相关服务..."
    systemctl stop pdns mariadb nginx $PHP_FPM_SERVICE
    if [ $? -eq 0 ]; then
        success "所有服务已停止"
    else
        error "部分服务停止失败"
    fi
}

# 6. 重启所有服务
restart_services() {
    detect_os
    info "正在重启所有相关服务..."
    systemctl restart pdns mariadb nginx $PHP_FPM_SERVICE
    if [ $? -eq 0 ]; then
        success "所有服务重启成功"
    else
        error "部分服务重启失败，请查看日志"
    fi
    show_status
}

# 7. 设置开机自启
enable_autostart() {
    detect_os
    info "正在设置所有服务开机自启..."
    systemctl enable pdns mariadb nginx $PHP_FPM_SERVICE
    if [ $? -eq 0 ]; then
        success "已设置所有服务开机自启"
    else
        error "设置开机自启失败"
    fi
}

# 8. 关闭开机自启
disable_autostart() {
    detect_os
    info "正在关闭所有服务开机自启..."
    systemctl disable pdns mariadb nginx $PHP_FPM_SERVICE
    if [ $? -eq 0 ]; then
        success "已关闭所有服务开机自启"
    else
        error "关闭开机自启失败"
    fi
}

# 9. 获取/重置API Key
get_apikey() {
    detect_os
    if [ ! -f $PDNS_CONF ]; then
        error "PowerDNS 配置文件不存在，请先安装 PowerDNS"
        return 1
    fi

    # 读取当前API Key
    CURRENT_API_KEY=$(grep -E '^api-key=' $PDNS_CONF | cut -d= -f2)
    if [ -z "$CURRENT_API_KEY" ]; then
        warn "当前 PowerDNS 未开启API或未配置API Key"
        read -p "是否开启API并配置API Key? [y/N]: " ENABLE_API
        ENABLE_API=${ENABLE_API,,}
        if [ "$ENABLE_API" != "y" ]; then
            return 0
        fi
        # 生成并配置API
        NEW_API_KEY=$(generate_random 32)
        cat >> $PDNS_CONF << EOF

# API 配置
api=yes
api-key=$NEW_API_KEY
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
webserver-allow-from=0.0.0.0/0
webserver-password=$NEW_API_KEY
EOF
        # 重启服务
        systemctl restart pdns
        if [ $? -eq 0 ]; then
            success "API已开启，新的API Key: $NEW_API_KEY"
        else
            error "PowerDNS 服务重启失败，请检查配置文件"
        fi
        return 0
    fi

    # 输出当前API Key
    echo ""
    info "当前 PowerDNS API Key: $CURRENT_API_KEY"
    echo ""

    # 重置API Key
    read -p "是否重置API Key? [y/N]: " RESET_KEY
    RESET_KEY=${RESET_KEY,,}
    if [ "$RESET_KEY" != "y" ]; then
        return 0
    fi

    # 生成新Key并更新配置
    NEW_API_KEY=$(generate_random 32)
    sed -i "s/^api-key=.*/api-key=$NEW_API_KEY/g" $PDNS_CONF
    sed -i "s/^webserver-password=.*/webserver-password=$NEW_API_KEY/g" $PDNS_CONF
    # 重启服务
    info "正在重启 PowerDNS 服务以应用新的API Key..."
    systemctl restart pdns
    if [ $? -eq 0 ]; then
        success "API Key 重置成功"
        info "新的API Key: $NEW_API_KEY"
        warn "请同步更新PowerAdmin等对接API的服务的配置"
    else
        error "PowerDNS 服务重启失败，请检查配置文件"
    fi
}

# 10. 查看服务状态
show_status() {
    detect_os
    echo ""
    info "================================= 服务运行状态 =================================="
    # 检查服务状态
    if systemctl is-active --quiet pdns; then
        echo -e "PowerDNS 服务: \033[32m运行中\033[0m"
    else
        echo -e "PowerDNS 服务: \033[31m已停止\033[0m"
    fi
    if systemctl is-active --quiet mariadb; then
        echo -e "MariaDB 服务: \033[32m运行中\033[0m"
    else
        echo -e "MariaDB 服务: \033[31m已停止\033[0m"
    fi
    if systemctl is-active --quiet nginx; then
        echo -e "Nginx 服务: \033[32m运行中\033[0m"
    else
        echo -e "Nginx 服务: \033[31m已停止\033[0m"
    fi
    if systemctl is-active --quiet $PHP_FPM_SERVICE; then
        echo -e "PHP-FPM 服务: \033[32m运行中\033[0m"
    else
        echo -e "PHP-FPM 服务: \033[31m已停止\033[0m"
    fi
    echo ""
    # 端口监听
    info "================================= 端口监听状态 =================================="
    echo "53端口(DNS):"
    ss -lnp | grep -E ':53\s' 2>/dev/null || echo "未监听"
    echo ""
    echo "80端口(Web):"
    ss -lnp | grep -E ':80\s' 2>/dev/null || echo "未监听"
    echo ""
    echo "8081端口(API):"
    ss -lnp | grep -E ':8081\s' 2>/dev/null || echo "未监听"
    echo ""
}

# ===================== 主菜单 =====================
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
        echo "==================== PowerDNS 全功能管理脚本 ===================="
        echo "1.  安装 PowerDNS 主节点（含PowerAdmin、数据库、API）"
        echo "2.  安装 PowerDNS 从节点（多节点扩展）"
        echo "3.  卸载 PowerDNS 及所有相关组件"
        echo "4.  启动 所有相关服务"
        echo "5.  停止 所有相关服务"
        echo "6.  重启 所有相关服务"
        echo "7.  设置开机自启（所有服务）"
        echo "8.  关闭开机自启（所有服务）"
        echo "9.  获取/重置 PowerDNS API Key"
        echo "10. 查看服务运行状态"
        echo "0.  退出脚本"
        echo "=================================================================="
        read -p "请输入您的选择 [0-10]: " CHOICE
        echo ""

        case $CHOICE in
            1)
                install_master
                ;;
            2)
                install_slave
                ;;
            3)
                uninstall_all
                ;;
            4)
                start_services
                ;;
            5)
                stop_services
                ;;
            6)
                restart_services
                ;;
            7)
                enable_autostart
                ;;
            8)
                disable_autostart
                ;;
            9)
                get_apikey
                ;;
            10)
                show_status
                ;;
            0)
                info "感谢使用，脚本退出"
                exit 0
                ;;
            *)
                error "无效的选择，请输入0-10之间的数字"
                ;;
        esac
    done
}

# 执行主函数
main "$@"
