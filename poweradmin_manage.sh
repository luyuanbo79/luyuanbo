#!/bin/bash
set -euo pipefail

# 权限强制检查：必须root用户运行
if [[ $EUID -ne 0 ]]; then
    echo -e "\033[0;31m[ERROR]\033[0m 此脚本必须以root用户运行，请使用sudo或切换root后执行"
    exit 1
fi

# 终端颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# 日志输出函数
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# 全局变量定义
PA_WEB_DIR="/var/www/poweradmin"
PDNS_CONF_PATH="/etc/powerdns/pdns.conf"
# PowerDNS全局配置变量（自动读取填充）
PDNS_DNS_PORT=""
PDNS_WEBSERVER_ENABLE=""
PDNS_WEBSERVER_PORT=""
PDNS_API_ENABLE=""
PDNS_API_KEY=""
PDNS_API_ALLOW_FROM=""

# 系统发行版检测与环境适配（核心兼容逻辑，修复PHP检测时机）
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "无法检测系统发行版，仅支持Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux系列"
        exit 1
    fi
    . /etc/os-release
    OS=$ID
    VERSION_ID=$VERSION_ID
    log_info "检测到系统：$OS $VERSION_ID"

    # 系统适配变量初始化
    if [[ $OS == @(debian|ubuntu) ]]; then
        PKG_MANAGER="apt"
        PKG_UPDATE="apt update -y"
        PKG_INSTALL="apt install -y"
        PKG_REMOVE="apt remove -y --purge"
        PKG_AUTOCLEAN="apt autoremove -y --purge"
        # 软件包定义
        NGINX_PACKAGE="nginx"
        PHP_PACKAGES="php-fpm php-mysql php-curl php-mbstring php-xml php-intl"
        # 配置路径适配
        NGINX_CONF_DIR="/etc/nginx/sites-available"
        NGINX_ENABLE_DIR="/etc/nginx/sites-enabled"
        NGINX_DEFAULT_CONF="$NGINX_ENABLE_DIR/default"
        # Web运行用户适配
        WWW_USER="www-data"
        WWW_GROUP="www-data"
    elif [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        PKG_MANAGER="dnf"
        [[ $VERSION_ID -eq 7 ]] && PKG_MANAGER="yum"
        PKG_UPDATE="$PKG_MANAGER makecache -y"
        PKG_INSTALL="$PKG_MANAGER install -y"
        PKG_REMOVE="$PKG_MANAGER remove -y"
        PKG_AUTOCLEAN="$PKG_MANAGER autoremove -y"
        # 软件包定义
        EPEL_PACKAGE="epel-release"
        NGINX_PACKAGE="nginx"
        PHP_PACKAGES="php-fpm php-mysqlnd php-curl php-mbstring php-xml php-intl"
        # 配置路径适配
        NGINX_CONF_DIR="/etc/nginx/conf.d"
        NGINX_ENABLE_DIR=""
        NGINX_DEFAULT_CONF="$NGINX_CONF_DIR/default.conf"
        # Web运行用户适配
        WWW_USER="nginx"
        WWW_GROUP="nginx"
    else
        log_error "不支持的系统：$OS，仅支持Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux系列"
        exit 1
    fi
}

# PHP-FPM信息获取（仅在PHP安装完成后调用，修复提前调用报错问题）
get_php_info() {
    if [[ $OS == @(debian|ubuntu) ]]; then
        PHP_FPM_SERVICE=$(systemctl list-unit-files | grep -E 'php.*fpm\.service' | awk '{print $1}' | head -n 1)
        PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION.'.'.PHP_MINOR_VERSION;" 2>/dev/null || echo "")
        PHP_FPM_SOCKET="/run/php/php${PHP_VERSION}-fpm.sock"
    else
        PHP_FPM_SERVICE="php-fpm.service"
        PHP_FPM_SOCKET="/run/php-fpm/www.sock"
    fi

    # 兜底处理：socket不存在则用TCP端口
    if [[ ! -S $PHP_FPM_SOCKET ]]; then
        log_warn "未检测到PHP-FPM socket，自动切换为127.0.0.1:9000"
        PHP_FPM_SOCKET="127.0.0.1:9000"
    fi
    log_info "PHP-FPM环境适配完成，服务名：$PHP_FPM_SERVICE，通信地址：$PHP_FPM_SOCKET"
}

# 本地PowerDNS环境检查+端口/API配置读取与自动配置（新增核心功能）
check_and_config_pdns() {
    log_info "===== 检查本地PowerDNS环境并读取核心配置 ====="
    # 检查PowerDNS配置文件是否存在
    if [[ ! -f $PDNS_CONF_PATH ]]; then
        log_error "未检测到本地PowerDNS配置文件：$PDNS_CONF_PATH"
        log_error "请先安装PowerDNS主节点，再安装PowerAdmin"
        exit 1
    fi

    # 1. 读取PowerDNS数据库核心配置（原有功能）
    PDNS_DB_HOST=$(grep -w "gmysql-host" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "127.0.0.1")
    PDNS_DB_PORT=$(grep -w "gmysql-port" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo 3306)
    PDNS_DB_NAME=$(grep -w "gmysql-dbname" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "")
    PDNS_DB_USER=$(grep -w "gmysql-user" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "")
    PDNS_DB_PASS=$(grep -w "gmysql-password" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "")

    if [[ -z $PDNS_DB_NAME || -z $PDNS_DB_USER || -z $PDNS_DB_PASS ]]; then
        log_error "无法从PowerDNS配置中读取数据库信息，请确认PowerDNS已正确安装并使用MySQL后端"
        exit 1
    fi

    # 检查数据库连通性
    if ! mysql -h$PDNS_DB_HOST -P$PDNS_DB_PORT -u$PDNS_DB_USER -p$PDNS_DB_PASS -e "use $PDNS_DB_NAME;" 2>/dev/null; then
        log_error "PowerDNS数据库连接失败，请确认MariaDB/MySQL服务正常运行"
        exit 1
    fi
    log_info "✅ PowerDNS数据库配置读取成功，连通性正常"

    # 2. 新增：读取PowerDNS端口、API核心配置
    PDNS_DNS_PORT=$(grep -w "local-port" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "53")
    PDNS_WEBSERVER_ENABLE=$(grep -w "webserver" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "no")
    PDNS_WEBSERVER_PORT=$(grep -w "webserver-port" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "8081")
    PDNS_API_ENABLE=$(grep -w "api" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "no")
    PDNS_API_KEY=$(grep -w "api-key" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "")
    PDNS_API_ALLOW_FROM=$(grep -w "allow-from" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "127.0.0.0/8, ::1/128")

    # 输出读取到的PowerDNS配置
    log_info "✅ 读取到PowerDNS核心配置："
    echo "  DNS服务监听端口：$PDNS_DNS_PORT"
    echo "  WebServer状态：$PDNS_WEBSERVER_ENABLE"
    echo "  API功能状态：$PDNS_API_ENABLE"
    if [[ -n $PDNS_API_KEY ]]; then
        echo "  API密钥已配置"
    else
        echo "  API密钥：未配置"
    fi

    # 3. 新增：自动配置PowerDNS API与WebServer（未开启时自动引导配置）
    if [[ $PDNS_API_ENABLE != "yes" || $PDNS_WEBSERVER_ENABLE != "yes" || -z $PDNS_API_KEY ]]; then
        log_warn "检测到PowerDNS的WebServer/API功能未完全开启/未配置密钥"
        read -p "是否自动开启PowerDNS API与WebServer并生成强密钥？(yes/no，默认yes)：" CONFIG_API
        CONFIG_API=${CONFIG_API:-yes}
        if [[ $CONFIG_API == "yes" ]]; then
            log_info "正在自动配置PowerDNS API与WebServer..."
            # 备份原配置文件
            cp $PDNS_CONF_PATH ${PDNS_CONF_PATH}.bak.$(date +%Y%m%d%H%M%S)
            log_info "已备份PowerDNS原配置文件至${PDNS_CONF_PATH}.bak.$(date +%Y%m%d%H%M%S)"

            # 生成强API密钥
            NEW_API_KEY=$(openssl rand -hex 32)
            # 写入/更新配置
            sed -i '/^webserver=/d' $PDNS_CONF_PATH
            sed -i '/^webserver-port=/d' $PDNS_CONF_PATH
            sed -i '/^webserver-address=/d' $PDNS_CONF_PATH
            sed -i '/^webserver-allow-from=/d' $PDNS_CONF_PATH
            sed -i '/^api=/d' $PDNS_CONF_PATH
            sed -i '/^api-key=/d' $PDNS_CONF_PATH
            sed -i '/^allow-from=/d' $PDNS_CONF_PATH

            # 追加配置
            cat >> $PDNS_CONF_PATH <<EOF

# PowerAdmin&API管理配置（自动生成）
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
webserver-allow-from=127.0.0.0/8,::1/128
api=yes
api-key=$NEW_API_KEY
allow-from=127.0.0.0/8,::1/128
EOF

            # 重启PowerDNS使配置生效
            log_info "正在重启PowerDNS服务使API配置生效..."
            if systemctl restart pdns; then
                # 更新全局变量
                PDNS_WEBSERVER_ENABLE="yes"
                PDNS_WEBSERVER_PORT="8081"
                PDNS_API_ENABLE="yes"
                PDNS_API_KEY=$NEW_API_KEY
                log_info "✅ PowerDNS API与WebServer配置完成，已重启生效"
                log_info "✅ 生成的API密钥：$NEW_API_KEY（请妥善保管）"
            else
                log_error "PowerDNS重启失败，请检查配置文件：$PDNS_CONF_PATH"
                exit 1
            fi
        else
            log_warn "已跳过PowerDNS API配置，部分高级功能可能无法使用"
        fi
    else
        log_info "✅ PowerDNS API与WebServer已正常配置，无需修改"
    fi

    log_info "===== PowerDNS环境检查与配置完成 ====="
}

# 防火墙与SELinux配置（新增API端口放行）
configure_firewall() {
    log_info "正在配置防火墙与系统权限规则..."
    # 防火墙适配
    if [[ $OS == @(debian|ubuntu) ]]; then
        if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
            ufw allow 80/tcp
            ufw allow 443/tcp
            # 放行PowerDNS API端口
            if [[ $PDNS_WEBSERVER_ENABLE == "yes" && -n $PDNS_WEBSERVER_PORT ]]; then
                ufw allow $PDNS_WEBSERVER_PORT/tcp
                log_info "已开放PowerDNS API/WebServer $PDNS_WEBSERVER_PORT 端口（TCP）"
            fi
            ufw reload
            log_info "已开放Web 80/443端口（TCP）"
        fi
    elif [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        if command -v firewalld &>/dev/null && systemctl is-active --quiet firewalld; then
            firewall-cmd --permanent --add-port=80/tcp
            firewall-cmd --permanent --add-port=443/tcp
            # 放行PowerDNS API端口
            if [[ $PDNS_WEBSERVER_ENABLE == "yes" && -n $PDNS_WEBSERVER_PORT ]]; then
                firewall-cmd --permanent --add-port=$PDNS_WEBSERVER_PORT/tcp
                log_info "已开放PowerDNS API/WebServer $PDNS_WEBSERVER_PORT 端口（TCP）"
            fi
            firewall-cmd --reload
            log_info "已开放Web 80/443端口（TCP）"
        fi

        # SELinux权限适配（解决RHEL系PHP连不上数据库、访问目录权限问题）
        if command -v getenforce &>/dev/null && [[ $(getenforce) != "Disabled" ]]; then
            setsebool -P httpd_can_network_connect on
            setsebool -P httpd_can_network_connect_db on
            setsebool -P httpd_unified on
            log_info "SELinux权限规则配置完成"
        fi
    fi
}

# 1. 安装PowerAdmin（自动对接本地PowerDNS）
install_poweradmin() {
    detect_os
    # 先检查并配置PowerDNS（含端口、API读取与配置）
    check_and_config_pdns

    # 1. 安装运行环境依赖
    log_info "开始安装Nginx+PHP运行环境..."
    if [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
        $PKG_INSTALL $EPEL_PACKAGE
    fi
    $PKG_UPDATE
    $PKG_INSTALL $NGINX_PACKAGE $PHP_PACKAGES curl tar

    # 安装完成后再获取PHP信息（修复原bug）
    get_php_info

    # 检查依赖服务是否安装成功
    if ! command -v nginx &>/dev/null; then
        log_error "Nginx安装失败，请检查软件源"
        exit 1
    fi
    if ! command -v php &>/dev/null; then
        log_error "PHP安装失败，请检查软件源"
        exit 1
    fi

    # 2. 启动基础服务并设置自启
    log_info "启动Nginx与PHP-FPM服务..."
    systemctl enable --now nginx
    systemctl enable --now $PHP_FPM_SERVICE

    # 检查服务状态
    if ! systemctl is-active --quiet nginx; then
        log_error "Nginx启动失败，请执行 systemctl status nginx 查看错误"
        exit 1
    fi
    if ! systemctl is-active --quiet $PHP_FPM_SERVICE; then
        log_error "PHP-FPM启动失败，请执行 systemctl status $PHP_FPM_SERVICE 查看错误"
        exit 1
    fi
    log_info "Nginx与PHP-FPM服务运行正常"

    # 3. 下载PowerAdmin最新稳定版（内置国内加速，解决GitHub访问问题）
    log_info "开始下载PowerAdmin最新稳定版..."
    if [[ -d $PA_WEB_DIR ]]; then
        log_warn "检测到已存在PowerAdmin目录，将自动备份原有文件"
        mv $PA_WEB_DIR ${PA_WEB_DIR}.bak.$(date +%Y%m%d%H%M%S)
    fi
    mkdir -p $PA_WEB_DIR

    # 获取最新版本号+下载（双地址兜底，优先国内加速）
    LATEST_VERSION=$(curl -s --connect-timeout 10 https://gh.api.99988866.xyz/https://api.github.com/repos/poweradmin/poweradmin/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")' || echo "")
    if [[ -z $LATEST_VERSION ]]; then
        log_warn "无法获取最新版本号，将使用v3.8.2稳定版"
        LATEST_VERSION="v3.8.2"
    fi
    DOWNLOAD_URL="https://gh.api.99988866.xyz/https://github.com/poweradmin/poweradmin/archive/refs/tags/${LATEST_VERSION}.tar.gz"
    BACKUP_URL="https://github.com/poweradmin/poweradmin/archive/refs/tags/${LATEST_VERSION}.tar.gz"

    # 下载并解压
    if ! curl -L $DOWNLOAD_URL -o /tmp/poweradmin.tar.gz --connect-timeout 15 --retry 2; then
        log_warn "国内加速地址下载失败，切换官方地址重试"
        curl -L $BACKUP_URL -o /tmp/poweradmin.tar.gz --connect-timeout 15 --retry 2
    fi

    if [[ ! -f /tmp/poweradmin.tar.gz ]]; then
        log_error "PowerAdmin安装包下载失败，请检查服务器网络是否能访问GitHub"
        exit 1
    fi

    # 解压并清理安装包
    tar -zxf /tmp/poweradmin.tar.gz -C $PA_WEB_DIR --strip-components=1
    rm -f /tmp/poweradmin.tar.gz
    log_info "PowerAdmin安装包解压完成"

    # 4. 配置PowerAdmin数据库
    log_info "开始配置PowerAdmin数据库..."
    PA_DB="poweradmin"
    PA_USER="poweradmin"
    PA_PASS=$(openssl rand -hex 16)
    SESSION_KEY=$(openssl rand -hex 32)

    # 创建数据库与用户，授权PowerDNS库只读权限
    mysql -u root <<EOF
CREATE DATABASE IF NOT EXISTS $PA_DB CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '$PA_USER'@'localhost' IDENTIFIED BY '$PA_PASS';
GRANT ALL PRIVILEGES ON $PA_DB.* TO '$PA_USER'@'localhost';
GRANT SELECT,INSERT,UPDATE,DELETE ON $PDNS_DB_NAME.* TO '$PA_USER'@'localhost';
FLUSH PRIVILEGES;
EOF

    # 导入PowerAdmin表结构
    PA_SCHEMA_FILE="$PA_WEB_DIR/sql/poweradmin-mysql-db-structure.sql"
    if [[ ! -f $PA_SCHEMA_FILE ]]; then
        log_error "PowerAdmin数据库schema文件不存在：$PA_SCHEMA_FILE"
        exit 1
    fi
    mysql -u root $PA_DB < $PA_SCHEMA_FILE
    log_info "PowerAdmin数据库配置完成"

    # 5. 生成PowerAdmin主配置文件（自动对接本地PowerDNS）
    log_info "生成PowerAdmin配置文件..."
    PA_CONF_FILE="$PA_WEB_DIR/inc/config.inc.php"
    cp $PA_WEB_DIR/inc/config-me.inc.php $PA_CONF_FILE

    # 替换配置项（自动填充所有数据库信息，无需手动修改）
    sed -i "s/\$db_host = 'localhost';/\$db_host = '127.0.0.1';/g" $PA_CONF_FILE
    sed -i "s/\$db_user = 'poweradmin';/\$db_user = '$PA_USER';/g" $PA_CONF_FILE
    sed -i "s/\$db_pass = 'poweradminpassword';/\$db_pass = '$PA_PASS';/g" $PA_CONF_FILE
    sed -i "s/\$db_name = 'poweradmin';/\$db_name = '$PA_DB';/g" $PA_CONF_FILE
    # 对接本地PowerDNS数据库
    sed -i "s/\$pdns_db_name = 'powerdns';/\$pdns_db_name = '$PDNS_DB_NAME';/g" $PA_CONF_FILE
    sed -i "s/\$pdns_db_user = 'powerdns';/\$pdns_db_user = '$PDNS_DB_USER';/g" $PA_CONF_FILE
    sed -i "s/\$pdns_db_pass = 'powerdnspassword';/\$pdns_db_pass = '$PDNS_DB_PASS';/g" $PA_CONF_FILE
    # 安全配置
    sed -i "s/\$session_key = 'encryption key';/\$session_key = '$SESSION_KEY';/g" $PA_CONF_FILE
    sed -i "s/\$dnssec_enabled = false;/\$dnssec_enabled = true;/g" $PA_CONF_FILE
    # 对接PowerDNS API
    if [[ $PDNS_API_ENABLE == "yes" && -n $PDNS_API_KEY ]]; then
        sed -i "s/\$pdns_api_url = '';/\$pdns_api_url = 'http:\/\/127.0.0.1:$PDNS_WEBSERVER_PORT';/g" $PA_CONF_FILE
        sed -i "s/\$pdns_api_key = '';/\$pdns_api_key = '$PDNS_API_KEY';/g" $PA_CONF_FILE
        log_info "已自动将PowerDNS API配置写入PowerAdmin"
    fi

    # 权限配置（关键：避免403/500权限错误）
    chown -R $WWW_USER:$WWW_GROUP $PA_WEB_DIR
    chmod 640 $PA_CONF_FILE
    log_info "PowerAdmin配置文件生成完成，已自动对接本地PowerDNS"

    # 6. 配置Nginx虚拟主机
    log_info "配置Nginx站点..."
    # 获取服务器IP，用于默认访问地址
    SERVER_IP=$(hostname -I | awk '{print $1}')
    read -p "请输入访问域名/服务器IP（默认：$SERVER_IP）：" SERVER_NAME
    SERVER_NAME=${SERVER_NAME:-$SERVER_IP}

    # 生成Nginx配置文件（适配不同系统）
    if [[ $OS == @(debian|ubuntu) ]]; then
        PA_NGINX_CONF="$NGINX_CONF_DIR/poweradmin.conf"
        cat > $PA_NGINX_CONF <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    root $PA_WEB_DIR;
    index index.php index.html index.htm;

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
        # 启用站点，禁用默认站点
        ln -sf $PA_NGINX_CONF $NGINX_ENABLE_DIR/
        [[ -f $NGINX_DEFAULT_CONF ]] && unlink $NGINX_DEFAULT_CONF
    else
        PA_NGINX_CONF="$NGINX_CONF_DIR/poweradmin.conf"
        cat > $PA_NGINX_CONF <<EOF
server {
    listen 80;
    server_name $SERVER_NAME;
    root $PA_WEB_DIR;
    index index.php index.html index.htm;

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
        # 禁用默认站点
        [[ -f $NGINX_DEFAULT_CONF ]] && mv $NGINX_DEFAULT_CONF ${NGINX_DEFAULT_CONF}.bak
    fi

    # 验证Nginx配置是否正确
    if ! nginx -t; then
        log_error "Nginx配置测试失败，请检查配置文件"
        exit 1
    fi
    # 重载Nginx使配置生效
    systemctl reload nginx
    log_info "Nginx站点配置已生效"

    # 7. 防火墙配置
    configure_firewall

    # 8. 安装完成，输出完整信息（含新增的PowerDNS端口、API信息）
    log_info "====================================="
    log_info "🎉 PowerAdmin 安装完成！已自动对接本地PowerDNS"
    echo "【PowerAdmin面板信息】"
    echo "访问地址：http://$SERVER_NAME"
    echo "默认管理员账号：admin"
    echo "默认管理员密码：admin"
    echo "面板安装目录：$PA_WEB_DIR"
    echo ""
    echo "【PowerDNS核心信息】"
    echo "DNS服务端口：$PDNS_DNS_PORT"
    echo "API/WebServer状态：已开启"
    echo "API访问地址：http://$SERVER_IP:$PDNS_WEBSERVER_PORT"
    echo "API密钥：$PDNS_API_KEY"
    log_info "====================================="
    log_warn "【重要安全提醒1】请立即登录面板修改默认管理员密码！"
    log_warn "【重要安全提醒2】请执行以下命令删除安装目录，避免安全风险："
    log_warn "rm -rf $PA_WEB_DIR/install"
    log_warn "【重要安全提醒3】API密钥已自动生成，请妥善保管，请勿泄露给无关人员"
}

# 2. 启动PowerAdmin服务
start_poweradmin() {
    detect_os
    # 安装后才会有PHP信息，这里重新获取适配
    get_php_info 2>/dev/null || true
    log_info "正在启动PowerAdmin依赖服务（Nginx+PHP-FPM）..."

    # 启动服务
    systemctl start nginx
    [[ -n $PHP_FPM_SERVICE ]] && systemctl start $PHP_FPM_SERVICE

    # 检查状态
    if systemctl is-active --quiet nginx && ([[ -z $PHP_FPM_SERVICE ]] || systemctl is-active --quiet $PHP_FPM_SERVICE); then
        log_info "PowerAdmin服务启动成功，Web服务已正常运行"
    else
        log_error "服务启动失败，请分别检查Nginx和PHP-FPM状态"
        echo "Nginx状态：systemctl status nginx"
        [[ -n $PHP_FPM_SERVICE ]] && echo "PHP-FPM状态：systemctl status $PHP_FPM_SERVICE"
    fi
}

# 3. 停止PowerAdmin服务
stop_poweradmin() {
    detect_os
    get_php_info 2>/dev/null || true
    log_warn "正在停止PowerAdmin依赖服务，停止后将无法访问Web面板"
    systemctl stop nginx
    [[ -n $PHP_FPM_SERVICE ]] && systemctl stop $PHP_FPM_SERVICE
    log_info "PowerAdmin服务已停止"
}

# 4. 重启PowerAdmin服务
restart_poweradmin() {
    detect_os
    get_php_info 2>/dev/null || true
    log_info "正在重启PowerAdmin依赖服务..."
    systemctl restart nginx
    [[ -n $PHP_FPM_SERVICE ]] && systemctl restart $PHP_FPM_SERVICE

    if systemctl is-active --quiet nginx && ([[ -z $PHP_FPM_SERVICE ]] || systemctl is-active --quiet $PHP_FPM_SERVICE); then
        log_info "PowerAdmin服务重启成功"
    else
        log_error "服务重启失败，请检查服务日志"
    fi
}

# 5. 查看PowerAdmin服务状态（新增PowerDNS API状态查看）
status_poweradmin() {
    detect_os
    get_php_info 2>/dev/null || true
    log_info "===== PowerAdmin 服务状态 ====="
    echo -e "Nginx服务状态：\c"
    if systemctl is-active --quiet nginx; then
        echo -e "${GREEN}运行中${NC}"
        echo -e "Nginx开机自启：\c"
        if systemctl is-enabled --quiet nginx; then
            echo -e "${GREEN}已开启${NC}"
        else
            echo -e "${YELLOW}已关闭${NC}"
        fi
    else
        echo -e "${RED}已停止${NC}"
    fi

    echo -e "\nPHP-FPM服务状态：\c"
    if [[ -n $PHP_FPM_SERVICE && systemctl is-active --quiet $PHP_FPM_SERVICE ]]; then
        echo -e "${GREEN}运行中${NC}"
        echo -e "PHP-FPM开机自启：\c"
        if systemctl is-enabled --quiet $PHP_FPM_SERVICE; then
            echo -e "${GREEN}已开启${NC}"
        else
            echo -e "${YELLOW}已关闭${NC}"
        fi
    else
        echo -e "${RED}已停止/未安装${NC}"
    fi

    # 新增：PowerDNS API状态查看
    echo -e "\n【PowerDNS关联状态】"
    if [[ -f $PDNS_CONF_PATH ]]; then
        PDNS_API_STATUS=$(grep -w "api" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "no")
        PDNS_API_PORT=$(grep -w "webserver-port" $PDNS_CONF_PATH | awk -F= '{print $2}' | xargs 2>/dev/null || echo "8081")
        echo -e "PowerDNS API功能：$([[ $PDNS_API_STATUS == "yes" ]] && echo -e "${GREEN}已开启${NC}" || echo -e "${YELLOW}已关闭${NC}")"
        echo -e "PowerDNS API端口：$PDNS_API_PORT"
    else
        echo -e "PowerDNS配置文件：${RED}未找到${NC}"
    fi

    # 访问地址信息
    if [[ -f /etc/nginx/sites-available/poweradmin.conf ]]; then
        SERVER_NAME=$(grep -w "server_name" /etc/nginx/sites-available/poweradmin.conf | awk '{print $2}' | sed 's/;//g')
    elif [[ -f /etc/nginx/conf.d/poweradmin.conf ]]; then
        SERVER_NAME=$(grep -w "server_name" /etc/nginx/conf.d/poweradmin.conf | awk '{print $2}' | sed 's/;//g')
    else
        SERVER_NAME="未检测到站点配置"
    fi
    echo -e "\n面板访问地址：http://$SERVER_NAME"
    echo -e "面板安装目录：$PA_WEB_DIR"
    log_info "================================"
}

# 6. 设置PowerAdmin开机自启
enable_autostart() {
    detect_os
    get_php_info 2>/dev/null || true
    log_info "正在设置PowerAdmin开机自启（Nginx+PHP-FPM）..."
    systemctl enable --now nginx
    [[ -n $PHP_FPM_SERVICE ]] && systemctl enable --now $PHP_FPM_SERVICE

    if systemctl is-enabled --quiet nginx && ([[ -z $PHP_FPM_SERVICE ]] || systemctl is-enabled --quiet $PHP_FPM_SERVICE); then
        log_info "PowerAdmin开机自启设置成功，服务器重启后将自动启动Web服务"
    else
        log_error "开机自启设置失败"
    fi
}

# 7. 关闭PowerAdmin开机自启
disable_autostart() {
    detect_os
    get_php_info 2>/dev/null || true
    log_warn "正在关闭PowerAdmin开机自启，服务器重启后Web服务将不会自动启动"
    systemctl disable nginx
    [[ -n $PHP_FPM_SERVICE ]] && systemctl disable $PHP_FPM_SERVICE
    log_info "PowerAdmin开机自启已关闭"
}

# 8. 完全卸载PowerAdmin
uninstall_poweradmin() {
    detect_os
    get_php_info 2>/dev/null || true
    log_warn "【警告】此操作将卸载PowerAdmin，可选择是否删除配置、数据库、依赖包，数据删除后无法恢复！"
    read -p "是否确认继续卸载？请输入 yes 确认：" CONFIRM
    [[ $CONFIRM != "yes" ]] && { log_info "已取消卸载操作"; return; }

    # 1. 停止服务
    log_info "停止PowerAdmin相关服务..."
    systemctl stop nginx || true
    [[ -n $PHP_FPM_SERVICE ]] && systemctl stop $PHP_FPM_SERVICE || true
    systemctl disable nginx || true
    [[ -n $PHP_FPM_SERVICE ]] && systemctl disable $PHP_FPM_SERVICE || true

    # 2. 删除面板文件
    read -p "是否删除PowerAdmin面板Web文件？输入 yes 确认：" DEL_WEB
    if [[ $DEL_WEB == "yes" ]]; then
        rm -rf $PA_WEB_DIR
        rm -rf ${PA_WEB_DIR}.bak.*
        log_info "PowerAdmin面板文件已删除"
    else
        log_info "已保留面板Web文件"
    fi

    # 3. 删除Nginx配置
    read -p "是否删除PowerAdmin的Nginx站点配置？输入 yes 确认：" DEL_NGINX_CONF
    if [[ $DEL_NGINX_CONF == "yes" ]]; then
        if [[ $OS == @(debian|ubuntu) ]]; then
            rm -f /etc/nginx/sites-available/poweradmin.conf
            rm -f /etc/nginx/sites-enabled/poweradmin.conf
        else
            rm -f /etc/nginx/conf.d/poweradmin.conf
        fi
        # 重载Nginx
        if systemctl is-active --quiet nginx; then
            nginx -t && systemctl reload nginx || true
        fi
        log_info "PowerAdmin Nginx配置已删除"
    else
        log_info "已保留Nginx配置"
    fi

    # 4. 删除数据库
    read -p "是否删除PowerAdmin数据库与用户？输入 yes 确认：" DEL_DB
    if [[ $DEL_DB == "yes" ]]; then
        if command -v mysql &>/dev/null; then
            mysql -u root <<EOF
DROP DATABASE IF EXISTS poweradmin;
DROP USER IF EXISTS 'poweradmin'@'localhost';
FLUSH PRIVILEGES;
EOF
            log_info "PowerAdmin数据库与用户已删除"
        else
            log_warn "未检测到mysql命令，跳过数据库删除"
        fi
    else
        log_info "已保留PowerAdmin数据库"
    fi

    # 5. 清理防火墙规则
    read -p "是否关闭80/443端口防火墙规则？输入 yes 确认：" DEL_FIREWALL
    if [[ $DEL_FIREWALL == "yes" ]]; then
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
        log_info "80/443端口防火墙规则已清理"
    else
        log_info "已保留防火墙规则"
    fi

    # 新增：清理PowerDNS API端口防火墙规则
    read -p "是否关闭PowerDNS API 8081端口防火墙规则？输入 yes 确认：" DEL_API_PORT
    if [[ $DEL_API_PORT == "yes" ]]; then
        if [[ $OS == @(debian|ubuntu) ]]; then
            if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
                ufw delete allow 8081/tcp || true
                ufw reload
            fi
        elif [[ $OS == @(centos|rhel|rocky|almalinux) ]]; then
            if command -v firewalld &>/dev/null && systemctl is-active --quiet firewalld; then
                firewall-cmd --permanent --remove-port=8081/tcp || true
                firewall-cmd --reload
            fi
        fi
        log_info "PowerDNS API 8081端口防火墙规则已清理"
    else
        log_info "已保留API端口防火墙规则"
    fi

    # 6. 卸载运行依赖
    read -p "是否卸载Nginx和PHP依赖包？输入 yes 确认：" DEL_DEP
    if [[ $DEL_DEP == "yes" ]]; then
        $PKG_REMOVE $NGINX_PACKAGE $PHP_PACKAGES
        $PKG_AUTOCLEAN
        log_info "Nginx和PHP依赖包已卸载"
    else
        log_info "已保留Nginx和PHP依赖包"
    fi

    log_info "PowerAdmin卸载操作执行完成"
}

# 9. 新增：单独查看/配置PowerDNS API功能
config_pdns_api_alone() {
    detect_os
    check_and_config_pdns
    echo ""
    read -p "按回车键返回主菜单..."
}

# 菜单展示函数（新增API配置菜单）
show_menu() {
    clear
    echo "====================================="
    echo "  PowerAdmin 全功能自动化管理脚本"
    echo "  自动对接本地PowerDNS | 全系统兼容 | 全生命周期管理"
    echo "====================================="
    echo "【安装部署】"
    echo " 1. 安装PowerAdmin（自动对接本地PowerDNS）"
    echo " 2. 单独配置PowerDNS API/端口（无需安装面板）"
    echo "-------------------------------------"
    echo "【服务管理】"
    echo " 3. 启动PowerAdmin服务"
    echo " 4. 停止PowerAdmin服务"
    echo " 5. 重启PowerAdmin服务"
    echo " 6. 查看PowerAdmin服务状态"
    echo "-------------------------------------"
    echo "【开机自启管理】"
    echo " 7. 设置PowerAdmin开机自启"
    echo " 8. 关闭PowerAdmin开机自启"
    echo "-------------------------------------"
    echo "【卸载清理】"
    echo " 9. 完全卸载PowerAdmin"
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
            1) install_poweradmin ;;
            2) config_pdns_api_alone ;;
            3) start_poweradmin ;;
            4) stop_poweradmin ;;
            5) restart_poweradmin ;;
            6) status_poweradmin ;;
            7) enable_autostart ;;
            8) disable_autostart ;;
            9) uninstall_poweradmin ;;
            0) log_info "脚本已退出，感谢使用"; exit 0 ;;
            *) log_error "无效的操作编号，请重新输入" ;;
        esac
        echo ""
        read -p "按回车键返回主菜单..."
    done
}

# 执行主程序
main
