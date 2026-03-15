#!/bin/bash
set -euo pipefail

# 权限检查：必须root运行
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m 此脚本必须以root用户运行，请使用sudo或切换root后执行"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 系统发行版检测与环境变量初始化
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测系统发行版，仅支持Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux"
        exit 1
    fi
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
    log_info "检测到系统：$OS $VERSION_ID"

    # 系统适配变量定义
    if [[ $OS == @(debian|ubuntu) ]]; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt update -y"
        PKG_INSTALL="apt install -y"
        PKG_REMOVE="apt remove -y --purge"
        PKG_AUTOCLEAN="apt autoremove -y --purge"
        PDNS_PACKAGE="pdns-server pdns-backend-mysql"
        MARIADB_PACKAGE="mariadb-server"
        NGINX_PACKAGE="nginx"
        PHP_PACKAGES="php-fpm php-mysql php-curl php-mbstring php-xml php-intl"
        NGINX_CONF_DIR="/etc/nginx/sites-available"
        NGINX_ENABLE_DIR="/etc/nginx/sites-enabled"
        WWW_USER="www-data"
        WWW_GROUP="www-data"
    elif [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        PKG_MANAGER="dnf"
        [[ $VERSION_ID -eq 7 ]] && PKG_MANAGER="yum"
        PKG_UPDATE="$PKG_MANAGER makecache -y"
        PKG_INSTALL="$PKG_MANAGER install -y"
        PKG_REMOVE="$PKG_MANAGER remove -y"
        PKG_AUTOCLEAN="$PKG_MANAGER autoremove -y"
        # PowerDNS官方源配置
        if [[ $VERSION_ID -eq 7 ]]; then
            PDNS_REPO_URL="https://repo.powerdns.com/repo-files/centos-7-auth-49.repo"
            EPEL_PACKAGE="epel-release"
        elif [[ $VERSION_ID -eq 8 ]]; then
            PDNS_REPO_URL="https://repo.powerdns.com/repo-files/centos-8-auth-49.repo"
            EPEL_PACKAGE="epel-release"
        elif [[ $VERSION_ID -eq 9 ]]; then
            PDNS_REPO_URL="https://repo.powerdns.com/repo-files/centos-9-auth-49.repo"
            EPEL_PACKAGE="epel-release"
        else
            log_error "不支持的RHEL系版本：$VERSION_ID"
            exit 1
        fi
        PDNS_PACKAGE="pdns pdns-backend-mysql"
        MARIADB_PACKAGE="mariadb-server"
        NGINX_PACKAGE="nginx"
        PHP_PACKAGES="php-fpm php-mysqlnd php-curl php-mbstring php-xml php-intl"
        NGINX_CONF_DIR="/etc/nginx/conf.d"
        NGINX_ENABLE_DIR=""
        WWW_USER="nginx"
        WWW_GROUP="nginx"
    else
        log_error "不支持的系统：$OS，仅支持Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux"
        exit 1
    fi
}

# 解决53端口占用（systemd-resolved）
fix_port_53_conflict() {
    log_info "检查53端口占用情况..."
    if lsof -i :53 2>/dev/null | grep -q "systemd-resolve"; then
        log_warn "检测到systemd-resolved占用53端口，正在自动处理..."
        sed -i 's/#DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
        sed -i 's/DNSStubListener=yes/DNSStubListener=no/g' /etc/systemd/resolved.conf
        systemctl daemon-reload
        systemctl restart systemd-resolved
        ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
        log_info "53端口占用已解决，系统DNS已配置为公共DNS"
    elif lsof -i :53 2>/dev/null | grep -v "COMMAND" | grep -q "LISTEN\|UDP"; then
        log_error "53端口被非systemd-resolved进程占用，请先停止对应服务再安装"
        lsof -i :53 2>/dev/null
        exit 1
    else
        log_info "53端口无占用，无需处理"
    fi
}

# 安装并初始化MariaDB数据库
install_mariadb() {
    log_info "开始安装MariaDB数据库..."
    $PKG_UPDATE
    $PKG_INSTALL $MARIADB_PACKAGE
    systemctl enable --now mariadb

    if ! systemctl is-active --quiet mariadb; then
        log_error "MariaDB启动失败，请检查系统日志"
        exit 1
    fi

    # 初始化数据库安全配置，生成root密码
    if [[ ! -f /root/.my.cnf ]]; then
        DB_ROOT_PASS=$(openssl rand -hex 16)
        mysql -u root <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$DB_ROOT_PASS';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test_%';
FLUSH PRIVILEGES;
EOF
        # 保存root密码，免密登录
        cat > /root/.my.cnf <<EOF
[client]
user=root
password=$DB_ROOT_PASS
EOF
        chmod 600 /root/.my.cnf
        log_info "MariaDB初始化完成，root密码已保存至/root/.my.cnf，请妥善保管"
    else
        log_info "检测到已存在MariaDB配置，跳过初始化"
        DB_ROOT_PASS=$(grep -w "password" /root/.my.cnf | awk '{print $3}')
    fi
}

# 生成PowerDNS数据库与用户
generate_pdns_db() {
    PDNS_DB="powerdns"
    PDNS_USER="powerdns"
    PDNS_PASS=$(openssl rand -hex 16)
    # 创建数据库与用户
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS $PDNS_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$PDNS_USER'@'localhost' IDENTIFIED BY '$PDNS_PASS';
GRANT ALL PRIVILEGES ON $PDNS_DB.* TO '$PDNS_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    log_info "PowerDNS数据库创建完成，用户名：$PDNS_USER，密码已自动生成"
}

# 防火墙与SELinux配置
configure_firewall() {
    local TYPE=$1
    log_info "正在配置防火墙与权限规则..."

    # 防火墙配置
    if [[ $OS == @(debian|ubuntu) ]]; then
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            if [[ $TYPE == "dns" ]]; then
                ufw allow 53/tcp
                ufw allow 53/udp
                log_info "已开放DNS 53端口（TCP/UDP）"
            elif [[ $TYPE == "web" ]]; then
                ufw allow 80/tcp
                ufw allow 443/tcp
                log_info "已开放Web 80/443端口（TCP）"
            fi
            ufw reload
        fi
    elif [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        if command -v firewalld &>/dev/null && systemctl is-active --quiet firewalld; then
            if [[ $TYPE == "dns" ]]; then
                firewall-cmd --permanent --add-port=53/tcp
                firewall-cmd --permanent --add-port=53/udp
                log_info "已开放DNS 53端口（TCP/UDP）"
            elif [[ $TYPE == "web" ]]; then
                firewall-cmd --permanent --add-port=80/tcp
                firewall-cmd --permanent --add-port=443/tcp
                log_info "已开放Web 80/443端口（TCP）"
            fi
            firewall-cmd --reload
        fi

        # SELinux配置
        if command -v getenforce &>/dev/null && [[ $(getenforce) != "Disabled" ]]; then
            if [[ $TYPE == "dns" ]]; then
                setsebool -P named_tcp_bind_all_ports on
                setsebool -P named_write_master_zones on
            elif [[ $TYPE == "web" ]]; then
                setsebool -P httpd_can_network_connect on
                setsebool -P httpd_can_network_connect_db on
            fi
            log_info "SELinux规则配置完成"
        fi
    fi
}

# 1. 安装PowerDNS主节点
install_pdns_master() {
    detect_os
    fix_port_53_conflict
    install_mariadb
    generate_pdns_db

    # 安装PowerDNS官方源（RHEL系）
    if [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        log_info "配置PowerDNS官方源..."
        $PKG_INSTALL $EPEL_PACKAGE
        curl -o /etc/yum.repos.d/powerdns-auth.repo $PDNS_REPO_URL -s
        $PKG_UPDATE
    fi

    # 安装PowerDNS
    log_info "安装PowerDNS服务..."
    $PKG_INSTALL $PDNS_PACKAGE

    # 导入数据库表结构
    log_info "导入PowerDNS数据库表结构..."
    if [[ $OS == @(debian|ubuntu) ]]; then
        SCHEMA_FILE="/usr/share/doc/pdns-backend-mysql/schema.mysql.sql"
        [[ -f ${SCHEMA_FILE}.gz ]] && gunzip -f ${SCHEMA_FILE}.gz
    else
        SCHEMA_FILE="/usr/share/doc/pdns/schema.mysql.sql"
    fi

    if [[ ! -f $SCHEMA_FILE ]]; then
        log_error "数据库schema文件不存在：$SCHEMA_FILE"
        exit 1
    fi
    mysql -u root $PDNS_DB < $SCHEMA_FILE

    # 备份原配置文件
    PDNS_CONF="/etc/powerdns/pdns.conf"
    [[ -f $PDNS_CONF ]] && cp $PDNS_CONF ${PDNS_CONF}.bak.$(date +%Y%m%d%H%M%S)

    # 生成主从同步TSIG密钥
    log_info "生成主从同步TSIG密钥..."
    TSIG_NAME="axfr-key"
    TSIG_KEY=$(pdnsutil generate-tsig-key $TSIG_NAME hmac-sha256)
    TSIG_FILE="/root/pdns_master_tsig.key"
    echo -e "PowerDNS主从同步密钥\n生成时间：$(date +%Y-%m-%d %H:%M:%S)\n密钥名称：$TSIG_NAME\n密钥内容：$TSIG_KEY" > $TSIG_FILE
    chmod 600 $TSIG_FILE
    log_info "TSIG密钥已保存至$TSIG_FILE，从节点配置需使用，请妥善保管"

    # 写入主节点配置
    cat > $PDNS_CONF <<EOF
# 基础配置
setuid=pdns
setgid=pdns
local-address=0.0.0.0
local-port=53
master=yes
slave=no
daemon=yes
guardian=yes
disable-axfr=no
allow-axfr-ips=0.0.0.0/0
also-notify=

# MySQL后端配置
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=$PDNS_DB
gmysql-user=$PDNS_USER
gmysql-password=$PDNS_PASS
gmysql-dnssec=yes

# 安全配置
allow-dnsupdate-from=127.0.0.0/8,::1/128
webserver=no
api=no

# 日志配置
loglevel=3
log-dns-details=yes
log-dns-queries=no
EOF

    # 启动服务并设置开机自启
    systemctl daemon-reload
    systemctl enable --now pdns

    if systemctl is-active --quiet pdns; then
        configure_firewall "dns"
        log_info "====================================="
        log_info "PowerDNS主节点安装完成！"
        echo "服务状态：已启动并设置开机自启"
        echo "服务端口：53（TCP/UDP）"
        echo "数据库名：$PDNS_DB"
        echo "数据库用户：$PDNS_USER"
        echo "TSIG密钥文件：$TSIG_FILE"
        log_info "====================================="
    else
        log_error "PowerDNS启动失败，请查看日志：journalctl -u pdns -n 20"
        exit 1
    fi
}

# 2. 安装PowerDNS从节点（多节点）
install_pdns_slave() {
    detect_os
    fix_port_53_conflict
    install_mariadb
    generate_pdns_db

    # 安装PowerDNS官方源（RHEL系）
    if [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        log_info "配置PowerDNS官方源..."
        $PKG_INSTALL $EPEL_PACKAGE
        curl -o /etc/yum.repos.d/powerdns-auth.repo $PDNS_REPO_URL -s
        $PKG_UPDATE
    fi

    # 安装PowerDNS
    log_info "安装PowerDNS服务..."
    $PKG_INSTALL $PDNS_PACKAGE

    # 导入数据库表结构
    log_info "导入PowerDNS数据库表结构..."
    if [[ $OS == @(debian|ubuntu) ]]; then
        SCHEMA_FILE="/usr/share/doc/pdns-backend-mysql/schema.mysql.sql"
        [[ -f ${SCHEMA_FILE}.gz ]] && gunzip -f ${SCHEMA_FILE}.gz
    else
        SCHEMA_FILE="/usr/share/doc/pdns/schema.mysql.sql"
    fi

    if [[ ! -f $SCHEMA_FILE ]]; then
        log_error "数据库schema文件不存在：$SCHEMA_FILE"
        exit 1
    fi
    mysql -u root $PDNS_DB < $SCHEMA_FILE

    # 备份原配置文件
    PDNS_CONF="/etc/powerdns/pdns.conf"
    [[ -f $PDNS_CONF ]] && cp $PDNS_CONF ${PDNS_CONF}.bak.$(date +%Y%m%d%H%M%S)

    # 获取主节点配置信息
    read -p "请输入主节点IP地址：" MASTER_IP
    [[ -z $MASTER_IP ]] && { log_error "主节点IP不能为空"; exit 1; }
    read -p "请输入主节点TSIG密钥名称（默认axfr-key）：" TSIG_NAME
    TSIG_NAME=${TSIG_NAME:-axfr-key}
    read -p "请输入主节点TSIG密钥完整内容：" TSIG_KEY
    [[ -z $TSIG_KEY ]] && { log_error "TSIG密钥不能为空"; exit 1; }

    # 写入从节点配置
    cat > $PDNS_CONF <<EOF
# 基础配置
setuid=pdns
setgid=pdns
local-address=0.0.0.0
local-port=53
master=no
slave=yes
daemon=yes
guardian=yes
disable-axfr=yes
tsig-axfr=yes

# 主节点配置
master=$MASTER_IP
$TSIG_KEY

# MySQL后端配置
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=$PDNS_DB
gmysql-user=$PDNS_USER
gmysql-password=$PDNS_PASS
gmysql-dnssec=yes

# 安全配置
allow-dnsupdate-from=
webserver=no
api=no

# 日志配置
loglevel=3
log-dns-details=yes
log-dns-queries=no
EOF

    # 启动服务并设置开机自启
    systemctl daemon-reload
    systemctl enable --now pdns

    if systemctl is-active --quiet pdns; then
        configure_firewall "dns"
        log_info "====================================="
        log_info "PowerDNS从节点安装完成！"
        echo "服务状态：已启动并设置开机自启"
        echo "服务端口：53（TCP/UDP）"
        echo "主节点IP：$MASTER_IP"
        echo "数据库名：$PDNS_DB"
        echo "数据库用户：$PDNS_USER"
        log_info "====================================="
        log_warn "请确保主节点防火墙已放行此从节点的53端口访问"
    else
        log_error "PowerDNS启动失败，请查看日志：journalctl -u pdns -n 20"
        exit 1
    fi
}

# 3. 安装PowerAdmin Web管理面板
install_poweradmin() {
    detect_os

    # 环境检查
    if ! command -v mysql &>/dev/null; then
        log_warn "未检测到MariaDB，将自动安装"
        install_mariadb
    fi
    if ! command -v pdns_control &>/dev/null; then
        log_error "未检测到PowerDNS服务，请先安装PowerDNS主节点"
        exit 1
    fi

    # 安装Nginx+PHP依赖
    log_info "安装Nginx与PHP运行环境..."
    $PKG_UPDATE
    $PKG_INSTALL $NGINX_PACKAGE $PHP_PACKAGES

    # 启动服务
    systemctl enable --now nginx
    if [[ $OS == @(debian|ubuntu) ]]; then
        PHP_FPM_SERVICE=$(systemctl list-unit-files | grep php-fpm | awk '{print $1}' | head -n 1)
    else
        PHP_FPM_SERVICE="php-fpm"
    fi
    systemctl enable --now $PHP_FPM_SERVICE

    # 检查服务状态
    if ! systemctl is-active --quiet nginx; then
        log_error "Nginx启动失败，请检查配置"
        exit 1
    fi
    if ! systemctl is-active --quiet $PHP_FPM_SERVICE; then
        log_error "PHP-FPM启动失败，请检查配置"
        exit 1
    fi

    # 下载PowerAdmin最新稳定版
    log_info "下载PowerAdmin最新版本..."
    PA_WEB_DIR="/var/www/poweradmin"
    mkdir -p $PA_WEB_DIR
    LATEST_VERSION=$(curl -s https://api.github.com/repos/poweradmin/poweradmin/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
    [[ -z $LATEST_VERSION ]] && { log_error "无法获取PowerAdmin最新版本"; exit 1; }
    DOWNLOAD_URL="https://github.com/poweradmin/poweradmin/archive/refs/tags/${LATEST_VERSION}.tar.gz"
    curl -L $DOWNLOAD_URL -o /tmp/poweradmin.tar.gz -s
    tar -zxf /tmp/poweradmin.tar.gz -C $PA_WEB_DIR --strip-components=1
    rm -f /tmp/poweradmin.tar.gz

    # 权限配置
    chown -R $WWW_USER:$WWW_GROUP $PA_WEB_DIR
    chmod -R 755 $PA_WEB_DIR

    # 数据库配置
    log_info "配置PowerAdmin数据库..."
    PA_DB="poweradmin"
    PA_USER="poweradmin"
    PA_PASS=$(openssl rand -hex 16)
    # 创建数据库与用户
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS $PA_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$PA_USER'@'localhost' IDENTIFIED BY '$PA_PASS';
GRANT ALL PRIVILEGES ON $PA_DB.* TO '$PA_USER'@'localhost';
GRANT SELECT,INSERT,UPDATE,DELETE ON powerdns.* TO '$PA_USER'@'localhost';
FLUSH PRIVILEGES;
EOF
    # 导入表结构
    PA_SCHEMA="$PA_WEB_DIR/sql/poweradmin-mysql-db-structure.sql"
    [[ -f $PA_SCHEMA ]] && mysql -u root $PA_DB < $PA_SCHEMA || { log_error "PowerAdmin schema文件不存在"; exit 1; }

    # Nginx配置
    log_info "配置Nginx虚拟主机..."
    read -p "请输入访问域名/服务器IP（默认本机IP）：" SERVER_NAME
    [[ -z $SERVER_NAME ]] && SERVER_NAME=$(hostname -I | awk '{print $1}')

    # PHP-FPM socket适配
    if [[ $OS == @(debian|ubuntu) ]]; then
        PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;")
        PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    else
        PHP_FPM_SOCKET="/run/php-fpm/www.sock"
    fi
    [[ ! -S $PHP_FPM_SOCKET ]] && { log_warn "未检测到PHP-FPM socket，将使用127.0.0.1:9000"; PHP_FPM_SOCKET="127.0.0.1:9000"; }

    # 生成Nginx配置
    if [[ $OS == @(debian|ubuntu) ]]; then
        NGINX_CONF="$NGINX_CONF_DIR/poweradmin.conf"
        cat > $NGINX_CONF <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    root $PA_WEB_DIR;
    index index.php index.html;

    access_log /var/log/nginx/poweradmin_access.log;
    error_log /var/log/nginx/poweradmin_error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$PHP_FPM_SOCKET;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF
        ln -sf $NGINX_CONF $NGINX_ENABLE_DIR/
        [[ -f $NGINX_ENABLE_DIR/default ]] && unlink $NGINX_ENABLE_DIR/default
    else
        NGINX_CONF="$NGINX_CONF_DIR/poweradmin.conf"
        cat > $NGINX_CONF <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    root $PA_WEB_DIR;
    index index.php index.html;

    access_log /var/log/nginx/poweradmin_access.log;
    error_log /var/log/nginx/poweradmin_error.log;

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
    fi

    # 重载Nginx配置
    if nginx -t; then
        systemctl reload nginx
        log_info "Nginx配置已生效"
    else
        log_error "Nginx配置测试失败，请检查配置文件"
        exit 1
    fi

    # 生成PowerAdmin配置文件
    log_info "生成PowerAdmin配置文件..."
    PA_CONF="$PA_WEB_DIR/inc/config.inc.php"
    cp $PA_WEB_DIR/inc/config-me.inc.php $PA_CONF
    # 读取PowerDNS数据库密码
    PDNS_PASS=$(grep -w "gmysql-password" /etc/powerdns/pdns.conf | awk -F= '{print $2}' | xargs)
    SESSION_KEY=$(openssl rand -hex 32)
    # 替换配置
    sed -i "s/\$db_host = 'localhost';/\$db_host = '127.0.0.1';/g" $PA_CONF
    sed -i "s/\$db_user = 'poweradmin';/\$db_user = '$PA_USER';/g" $PA_CONF
    sed -i "s/\$db_pass = 'poweradminpassword';/\$db_pass = '$PA_PASS';/g" $PA_CONF
    sed -i "s/\$db_name = 'poweradmin';/\$db_name = '$PA_DB';/g" $PA_CONF
    sed -i "s/\$pdns_db_name = 'powerdns';/\$pdns_db_name = 'powerdns';/g" $PA_CONF
    sed -i "s/\$pdns_db_user = 'powerdns';/\$pdns_db_user = 'powerdns';/g" $PA_CONF
    sed -i "s/\$pdns_db_pass = 'powerdnspassword';/\$pdns_db_pass = '$PDNS_PASS';/g" $PA_CONF
    sed -i "s/\$session_key = 'encryption key';/\$session_key = '$SESSION_KEY';/g" $PA_CONF
    # 权限配置
    chown $WWW_USER:$WWW_GROUP $PA_CONF
    chmod 640 $PA_CONF

    # 防火墙配置
    configure_firewall "web"

    # 输出完成信息
    log_info "====================================="
    log_info "PowerAdmin Web管理面板安装完成！"
    echo "访问地址：http://$SERVER_NAME"
    echo "默认管理员账号：admin"
    echo "默认管理员密码：admin"
    echo "数据库名：$PA_DB"
    echo "数据库用户：$PA_USER"
    log_info "====================================="
    log_warn "【安全提醒】请立即登录修改默认管理员密码！"
    log_warn "【安全提醒】安装完成后请删除 $PA_WEB_DIR/install 目录！"
}

# 4. 启动PowerDNS服务
start_pdns() {
    log_info "正在启动PowerDNS服务..."
    if systemctl start pdns; then
        log_info "PowerDNS服务启动成功"
    else
        log_error "启动失败，请查看日志：journalctl -u pdns -n 20"
    fi
}

# 5. 停止PowerDNS服务
stop_pdns() {
    log_info "正在停止PowerDNS服务..."
    if systemctl stop pdns; then
        log_info "PowerDNS服务已停止"
    else
        log_error "停止失败"
    fi
}

# 6. 重启PowerDNS服务
restart_pdns() {
    log_info "正在重启PowerDNS服务..."
    if systemctl restart pdns; then
        log_info "PowerDNS服务重启成功"
    else
        log_error "重启失败，请查看日志：journalctl -u pdns -n 20"
    fi
}

# 7. 查看PowerDNS服务状态
status_pdns() {
    log_info "PowerDNS服务当前状态："
    systemctl status pdns --no-pager -l
}

# 8. 设置开机自启
enable_autostart() {
    log_info "正在设置PowerDNS开机自启..."
    if systemctl enable --now pdns; then
        log_info "PowerDNS开机自启设置成功"
    else
        log_error "设置失败"
    fi
}

# 9. 关闭开机自启
disable_autostart() {
    log_info "正在关闭PowerDNS开机自启..."
    if systemctl disable --now pdns; then
        log_info "PowerDNS开机自启已关闭"
    else
        log_error "关闭失败"
    fi
}

# 10. 完全卸载PowerDNS
uninstall_pdns() {
    log_warn "【警告】此操作将完全卸载PowerDNS，包括服务、配置、数据库，数据将无法恢复！"
    read -p "是否确认卸载？请输入 yes 确认：" CONFIRM
    [[ $CONFIRM != "yes" ]] && { log_info "已取消卸载"; return; }

    detect_os

    # 停止并禁用服务
    log_info "停止并禁用PowerDNS服务..."
    systemctl stop pdns || true
    systemctl disable pdns || true

    # 卸载安装包
    log_info "卸载PowerDNS安装包..."
    $PKG_REMOVE $PDNS_PACKAGE
    $PKG_AUTOCLEAN

    # 删除配置文件
    log_info "删除PowerDNS配置文件..."
    rm -rf /etc/powerdns/
    rm -f /root/pdns_master_tsig.key

    # 数据库删除确认
    read -p "是否删除PowerDNS数据库（powerdns）？输入 yes 确认：" DEL_DB
    if [[ $DEL_DB == "yes" ]]; then
        if command -v mysql &>/dev/null; then
            mysql -u root <<EOF
DROP DATABASE IF EXISTS powerdns;
DROP USER IF EXISTS 'powerdns'@'localhost';
FLUSH PRIVILEGES;
EOF
            log_info "PowerDNS数据库已删除"
        else
            log_warn "未检测到mysql命令，跳过数据库删除"
        fi
    else
        log_info "已保留PowerDNS数据库"
    fi

    # 关闭防火墙端口
    log_info "清理防火墙规则..."
    if [[ $OS == @(debian|ubuntu) ]]; then
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw delete allow 53/tcp || true
            ufw delete allow 53/udp || true
            ufw reload
        fi
    elif [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        if command -v firewalld &>/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --remove-port=53/tcp || true
            firewall-cmd --permanent --remove-port=53/udp || true
            firewall-cmd --reload
        fi
    fi

    log_info "PowerDNS完全卸载完成"
}

# 11. 完全卸载PowerAdmin
uninstall_poweradmin() {
    log_warn "【警告】此操作将完全卸载PowerAdmin，包括Web文件、配置、数据库，数据将无法恢复！"
    read -p "是否确认卸载？请输入 yes 确认：" CONFIRM
    [[ $CONFIRM != "yes" ]] && { log_info "已取消卸载"; return; }

    detect_os

    # 删除Web文件
    log_info "删除PowerAdmin Web文件..."
    rm -rf /var/www/poweradmin

    # 删除Nginx配置
    log_info "删除Nginx配置..."
    if [[ $OS == @(debian|ubuntu) ]]; then
        rm -f /etc/nginx/sites-available/poweradmin.conf
        rm -f /etc/nginx/sites-enabled/poweradmin.conf
    else
        rm -f /etc/nginx/conf.d/poweradmin.conf
    fi
    # 重载Nginx
    if systemctl is-active --quiet nginx; then
        nginx -t && systemctl reload nginx
    fi

    # 数据库删除确认
    read -p "是否删除PowerAdmin数据库（poweradmin）？输入 yes 确认：" DEL_DB
    if [[ $DEL_DB == "yes" ]]; then
        if command -v mysql &>/dev/null; then
            mysql -u root <<EOF
DROP DATABASE IF EXISTS poweradmin;
DROP USER IF EXISTS 'poweradmin'@'localhost';
FLUSH PRIVILEGES;
EOF
            log_info "PowerAdmin数据库已删除"
        else
            log_warn "未检测到mysql命令，跳过数据库删除"
        fi
    else
        log_info "已保留PowerAdmin数据库"
    fi

    # 端口与依赖清理
    read -p "是否关闭80/443端口防火墙规则？输入 yes 确认：" DEL_PORT
    if [[ $DEL_PORT == "yes" ]]; then
        if [[ $OS == @(debian|ubuntu) ]]; then
            if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                ufw delete allow 80/tcp || true
                ufw delete allow 443/tcp || true
                ufw reload
            fi
        elif [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
            if command -v firewalld &>/dev/null && systemctl is-active --quiet firewalld; then
                firewall-cmd --permanent --remove-port=80/tcp || true
                firewall-cmd --permanent --remove-port=443/tcp || true
                firewall-cmd --reload
            fi
        fi
    fi

    read -p "是否卸载Nginx和PHP依赖包？输入 yes 确认：" DEL_PHP
    if [[ $DEL_PHP == "yes" ]]; then
        log_info "卸载Nginx和PHP依赖..."
        $PKG_REMOVE $NGINX_PACKAGE $PHP_PACKAGES
        $PKG_AUTOCLEAN
        systemctl stop nginx || true
        systemctl disable nginx || true
        local php_service=$(systemctl list-unit-files | grep php-fpm | awk '{print $1}' | head -n 1)
        [[ -n $php_service ]] && systemctl stop $php_service || true && systemctl disable $php_service || true
        log_info "Nginx和PHP依赖已卸载"
    fi

    log_info "PowerAdmin完全卸载完成"
}

# 菜单显示
show_menu() {
    clear
    echo "====================================="
    echo "  PowerDNS 全功能自动化管理脚本"
    echo "  支持主从多节点 | PowerAdmin面板 | 全生命周期管理"
    echo "====================================="
    echo "【安装部署】"
    echo " 1. 安装PowerDNS主节点"
    echo " 2. 安装PowerDNS从节点（多节点部署）"
    echo " 3. 安装PowerAdmin Web管理面板"
    echo "-------------------------------------"
    echo "【服务管理】"
    echo " 4. 启动PowerDNS服务"
    echo " 5. 停止PowerDNS服务"
    echo " 6. 重启PowerDNS服务"
    echo " 7. 查看PowerDNS服务状态"
    echo "-------------------------------------"
    echo "【开机自启管理】"
    echo " 8. 设置PowerDNS开机自启"
    echo " 9. 关闭PowerDNS开机自启"
    echo "-------------------------------------"
    echo "【卸载清理】"
    echo "10. 完全卸载PowerDNS"
    echo "11. 完全卸载PowerAdmin"
    echo "-------------------------------------"
    echo " 0. 退出脚本"
    echo "====================================="
    read -p "请输入要执行的操作编号：" MENU_CHOICE
}

# 主程序入口
main() {
    while true; do
        show_menu
        case $MENU_CHOICE in
            1) install_pdns_master ;;
            2) install_pdns_slave ;;
            3) install_poweradmin ;;
            4) start_pdns ;;
            5) stop_pdns ;;
            6) restart_pdns ;;
            7) status_pdns ;;
            8) enable_autostart ;;
            9) disable_autostart ;;
            10) uninstall_pdns ;;
            11) uninstall_poweradmin ;;
            0) log_info "脚本已退出，感谢使用"; exit 0 ;;
            *) log_error "无效的编号，请重新输入" ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..."
    done
}

# 执行主程序
main
