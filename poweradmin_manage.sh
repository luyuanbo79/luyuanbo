#!/bin/bash
set -euo pipefail

# ==================== 配置项（可自行修改）====================
DB_ROOT_PASS="root123456"          # MariaDB root密码
PDNS_DB_NAME="powerdns"            # PowerDNS库名
PDNS_DB_USER="pdns"                # PowerDNS数据库用户
PDNS_DB_PASS="pdns123456"          # PowerDNS数据库密码
PDNS_API_KEY="$(head -c 32 /dev/urandom | base64 | tr -d /=+ | head -c 32)" # 自动生成API Key
PDNS_WEB_PORT="8088"               # PowerAdmin网页端口
# ==============================================================

# 颜色输出
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
NC="\033[0m"

info() { echo -e "${GREEN}[INFO] $*${NC}"; }
warn() { echo -e "${YELLOW}[WARN] $*${NC}"; }
err() { echo -e "${RED}[ERROR] $*${NC}"; exit 1; }

# 系统判断
if [ -f /etc/redhat-release ]; then
  OS="el"
  PM="yum"
  WEBSVC="httpd"
else
  OS="deb"
  PM="apt"
  WEBSVC="apache2"
fi

# 菜单
menu() {
clear
echo "==================== PowerDNS 一键管理脚本 ===================="
echo " 1. 安装 PowerDNS + MariaDB + PowerAdmin（全新安装）"
echo " 2. 卸载 PowerDNS + MariaDB + PowerAdmin（清空数据）"
echo " 3. 启动 PowerDNS"
echo " 4. 停止 PowerDNS"
echo " 5. 重启 PowerDNS"
echo " 6. 设置 PowerDNS 开机自启"
echo " 7. 取消 PowerDNS 开机自启"
echo " 8. 查看 PowerDNS API Key"
echo " 0. 退出"
read -p "请输入选项 [0-8]: " opt
case $opt in
  1) install_all ;;
  2) uninstall_all ;;
  3) systemctl start pdns ; info "已启动 pdns" ;;
  4) systemctl stop pdns ; info "已停止 pdns" ;;
  5) systemctl restart pdns ; info "已重启 pdns" ;;
  6) systemctl enable pdns ; info "已设置开机自启" ;;
  7) systemctl disable pdns ; info "已取消开机自启" ;;
  8) show_api_key ;;
  0) exit 0 ;;
  *) warn "输入错误" && sleep 1 && menu ;;
esac
sleep 2
menu
}

# 安装依赖 + MariaDB
install_mariadb() {
info "安装 MariaDB..."
if [ "$OS" = "el" ]; then
  $PM install -y mariadb-server mariadb
  systemctl enable --now mariadb
else
  $PM update -y
  $PM install -y mariadb-server mariadb-client
  systemctl enable --now mariadb
fi

# 初始化数据库
mysql -uroot <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '${DB_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DELETE FROM mysql.user WHERE Host NOT IN ('localhost','127.0.0.1','::1');
DROP DATABASE IF EXISTS test;
FLUSH PRIVILEGES;
CREATE DATABASE IF NOT EXISTS ${PDNS_DB_NAME} DEFAULT CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '${PDNS_DB_USER}'@'localhost' IDENTIFIED BY '${PDNS_DB_PASS}';
GRANT ALL ON ${PDNS_DB_NAME}.* TO '${PDNS_DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
info "MariaDB 初始化完成"
}

# 安装 PowerDNS
install_pdns() {
info "安装 PowerDNS..."
if [ "$OS" = "el" ]; then
  $PM install -y epel-release
  $PM install -y pdns pdns-backend-mysql
else
  $PM install -y pdns-server pdns-backend-mysql
fi

# 写入 pdns.conf
cat > /etc/pdns/pdns.conf <<EOF
launch=gmysql
gmysql-host=127.0.0.1
gmysql-port=3306
gmysql-dbname=${PDNS_DB_NAME}
gmysql-user=${PDNS_DB_USER}
gmysql-password=${PDNS_DB_PASS}
gmysql-dnssec=yes

api=yes
api-key=${PDNS_API_KEY}
webserver=yes
webserver-address=0.0.0.0
webserver-port=8081
webserver-allow-from=0.0.0.0/0

daemon=yes
disable-axfr=no
local-address=0.0.0.0
local-port=53
EOF

# 导入官方表结构
curl -s https://raw.githubusercontent.com/PowerDNS/pdns/master/modules/gmysqlbackend/schema.mysql.sql | mysql -uroot -p${DB_ROOT_PASS} ${PDNS_DB_NAME}

systemctl daemon-reload
systemctl enable --now pdns
info "PowerDNS 安装并启动完成"
}

# 安装 PowerAdmin
install_poweradmin() {
info "安装 PowerAdmin + Web环境..."
if [ "$OS" = "el" ]; then
  $PM install -y httpd php php-mysqlnd php-json php-mbstring php-xml
  systemctl enable --now httpd
  sed -i 's/Listen 80/Listen ${PDNS_WEB_PORT}/' /etc/httpd/conf/httpd.conf
else
  $PM install -y apache2 php libapache2-mod-php php-mysql php-json php-mbstring php-xml
  systemctl enable --now apache2
  echo "Listen ${PDNS_WEB_PORT}" > /etc/apache2/ports.conf
fi

cd /var/www/html
rm -rf poweradmin
curl -L -o poweradmin.tar.gz https://github.com/poweradmin/poweradmin/archive/refs/tags/v2.2.1.tar.gz
tar zxf poweradmin.tar.gz
mv poweradmin-2.2.1 poweradmin
chown -R apache:apache /var/www/html/poweradmin 2>/dev/null || chown -R www-data:www-data /var/www/html/poweradmin

# 自动写入配置（免安装向导）
cat > /var/www/html/poweradmin/inc/config.inc.php <<EOF
<?php
\$db_host = '127.0.0.1';
\$db_port = '3306';
\$db_user = '${PDNS_DB_USER}';
\$db_pass = '${PDNS_DB_PASS}';
\$db_name = '${PDNS_DB_NAME}';
\$db_type = 'mysql';
\$dns_servers = array('127.0.0.1');
\$pdns_api_url = 'http://127.0.0.1:8081';
\$pdns_api_key = '${PDNS_API_KEY}';
\$session_key = '$(head -c 20 /dev/urandom | base64)';
\$iface_lang = 'en_EN';
?>
EOF

systemctl restart $WEBSVC
info "PowerAdmin 安装完成，端口：${PDNS_WEB_PORT}"
}

# 完整安装
install_all() {
install_mariadb
install_pdns
install_poweradmin
show_info
}

# 显示信息
show_info() {
echo -e "\n==================== 安装完成 ===================="
echo -e "PowerDNS API Key: ${YELLOW}${PDNS_API_KEY}${NC}"
echo -e "PowerAdmin 地址:  http://本机IP:${PDNS_WEB_PORT}/poweradmin"
echo -e "MariaDB root密码: ${DB_ROOT_PASS}"
echo -e "PowerDNS库: ${PDNS_DB_NAME} / 用户: ${PDNS_DB_USER} / 密码: ${PDNS_DB_PASS}"
echo "===================================================="
}

show_api_key() {
info "PowerDNS API Key: $(grep '^api-key' /etc/pdns/pdns.conf | awk -F= '{print $2}')"
}

# 卸载（清空数据）
uninstall_all() {
warn "确认卸载？所有数据会删除！(y/n)"
read -r confirm
[ "$confirm" != "y" ] && return

info "停止服务..."
systemctl stop pdns 2>/dev/null
systemctl stop mariadb 2>/dev/null
systemctl stop $WEBSVC 2>/dev/null

info "卸载软件..."
if [ "$OS" = "el" ]; then
  yum remove -y pdns* mariadb* httpd php
else
  apt remove -y pdns* mariadb* apache2 php
fi

info "删除数据..."
rm -rf /etc/pdns /var/lib/pdns
rm -rf /var/lib/mysql
rm -rf /var/www/html/poweradmin*
info "卸载完成"
}

# 启动
menu
