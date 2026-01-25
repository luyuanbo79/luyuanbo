#!/bin/bash
set -euo pipefail

# 彩色输出定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 核心配置（可根据需求修改）
QBIT_SERVICE="qbittorrent-nox@8080"  # 服务名，8080为WebUI端口
QBIT_PORT=8080                       # WebUI默认端口
QBIT_USER="root"                     # 运行用户（默认root，可改为普通用户）
DEFAULT_RESET_PWD="Qbittorrent@123"  # 重置密码默认值

# 检查是否为root/ sudo权限
check_root() {
    if [ $EUID -ne 0 ]; then
        echo -e "${RED}[错误] 请使用root或sudo运行此脚本！${NC}"
        exit 1
    fi
}

# 检查系统是否为systemd
check_systemd() {
    if [ ! -f /usr/lib/systemd/system/systemd.service ]; then
        echo -e "${RED}[错误] 仅支持systemd类型的Linux系统！${NC}"
        exit 1
    fi
}

# 1. 安装qbittorrent-nox
install_qbit() {
    check_root
    check_systemd
    if command -v qbittorrent-nox &>/dev/null; then
        echo -e "${YELLOW}[提示] qbittorrent-nox已安装，无需重复操作！${NC}"
        return
    fi

    echo -e "${BLUE}[开始] 检测包管理器并安装qbittorrent-nox...${NC}"
    # 适配apt/yum/dnf包管理器
    if command -v apt &>/dev/null; then
        apt update -y && apt install qbittorrent-nox -y
    elif command -v dnf &>/dev/null; then
        dnf install qbittorrent-nox -y
    elif command -v yum &>/dev/null; then
        yum install qbittorrent-nox -y
    else
        echo -e "${RED}[错误] 不支持的包管理器（仅支持apt/yum/dnf）！${NC}"
        exit 1
    fi

    # 创建systemd服务文件（部分系统默认无此文件，手动生成）
    SERVICE_FILE="/usr/lib/systemd/system/qbittorrent-nox@.service"
    if [ ! -f "$SERVICE_FILE" ]; then
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=qBittorrent-nox WebUI on port %i
Documentation=man:qbittorrent-nox(1)
After=network.target

[Service]
Type=exec
User=%I
ExecStart=/usr/bin/qbittorrent-nox --webui-port %i
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
    fi

    # 重载systemd配置
    systemctl daemon-reload
    echo -e "${GREEN}[成功] qbittorrent-nox安装完成，WebUI端口：${QBIT_PORT}${NC}"
}

# 2. 启动qbittorrent-nox
start_qbit() {
    check_root
    if ! command -v qbittorrent-nox &>/dev/null; then
        echo -e "${RED}[错误] 未安装qbittorrent-nox，请先执行安装！${NC}"
        return
    fi
    echo -e "${BLUE}[开始] 启动${QBIT_SERVICE}服务...${NC}"
    systemctl start "${QBIT_SERVICE}"
    echo -e "${GREEN}[成功] ${QBIT_SERVICE}已启动！${NC}"
}

# 3. 关闭qbittorrent-nox
stop_qbit() {
    check_root
    echo -e "${BLUE}[开始] 停止${QBIT_SERVICE}服务...${NC}"
    systemctl stop "${QBIT_SERVICE}" &>/dev/null || true
    echo -e "${GREEN}[成功] ${QBIT_SERVICE}已停止！${NC}"
}

# 4. 重启qbittorrent-nox
restart_qbit() {
    check_root
    if ! command -v qbittorrent-nox &>/dev/null; then
        echo -e "${RED}[错误] 未安装qbittorrent-nox，请先执行安装！${NC}"
        return
    fi
    echo -e "${BLUE}[开始] 重启${QBIT_SERVICE}服务...${NC}"
    systemctl restart "${QBIT_SERVICE}"
    echo -e "${GREEN}[成功] ${QBIT_SERVICE}已重启！${NC}"
}

# 5. 检测qbittorrent-nox状态
status_qbit() {
    check_root
    echo -e "${BLUE}[信息] ${QBIT_SERVICE}状态检测...${NC}"
    # 服务状态
    if systemctl is-active --quiet "${QBIT_SERVICE}"; then
        echo -e "服务状态：${GREEN}运行中${NC}"
    else
        echo -e "服务状态：${RED}未运行/已停止${NC}"
    fi
    # 端口监听
    if ss -tulnp | grep -q ":${QBIT_PORT}.*qbittorrent-nox"; then
        echo -e "端口${QBIT_PORT}：${GREEN}已监听${NC}"
    else
        echo -e "端口${QBIT_PORT}：${RED}未监听${NC}"
    fi
    # 进程存在性
    if pgrep -f qbittorrent-nox &>/dev/null; then
        echo -e "进程状态：${GREEN}存在${NC}"
    else
        echo -e "进程状态：${RED}不存在${NC}"
    fi
    # 自启动状态
    if systemctl is-enabled --quiet "${QBIT_SERVICE}"; then
        echo -e "自启动：${GREEN}已开启${NC}"
    else
        echo -e "自启动：${RED}已关闭${NC}"
    fi
}

# 6. 开启自启动
enable_auto() {
    check_root
    if ! command -v qbittorrent-nox &>/dev/null; then
        echo -e "${RED}[错误] 未安装qbittorrent-nox，请先执行安装！${NC}"
        return
    fi
    echo -e "${BLUE}[开始] 开启${QBIT_SERVICE}开机自启动...${NC}"
    systemctl enable --now "${QBIT_SERVICE}"
    echo -e "${GREEN}[成功] ${QBIT_SERVICE}自启动已开启！${NC}"
}

# 7. 关闭自启动
disable_auto() {
    check_root
    echo -e "${BLUE}[开始] 关闭${QBIT_SERVICE}开机自启动...${NC}"
    systemctl disable --now "${QBIT_SERVICE}" &>/dev/null || true
    echo -e "${GREEN}[成功] ${QBIT_SERVICE}自启动已关闭！${NC}"
}

# 8. 修改WebUI密码（自定义）
change_pwd() {
    check_root
    if ! command -v qbittorrent-nox &>/dev/null; then
        echo -e "${RED}[错误] 未安装qbittorrent-nox，请先执行安装！${NC}"
        return
    fi
    if ! systemctl is-active --quiet "${QBIT_SERVICE}"; then
        echo -e "${YELLOW}[提示] 服务未运行，将启动服务后修改密码...${NC}"
        start_qbit
    fi

    # 两次输入密码，确认一致性
    read -s -p "请输入新的WebUI密码：" NEW_PWD1
    echo
    read -s -p "请再次输入新的WebUI密码：" NEW_PWD2
    echo
    if [ "$NEW_PWD1" != "$NEW_PWD2" ]; then
        echo -e "${RED}[错误] 两次输入的密码不一致！${NC}"
        return
    fi
    if [ -z "$NEW_PWD1" ]; then
        echo -e "${RED}[错误] 密码不能为空！${NC}"
        return
    fi

    echo -e "${BLUE}[开始] 修改WebUI密码...${NC}"
    # qbittorrent-nox 命令行改密码（管道自动输入）
    echo -e "$NEW_PWD1\n$NEW_PWD1" | qbittorrent-nox --webui-port "${QBIT_PORT}" --change-webui-password
    echo -e "${GREEN}[成功] WebUI密码修改完成！${NC}"
}

# 9. 重置WebUI密码（使用默认密码）
reset_pwd() {
    check_root
    if ! command -v qbittorrent-nox &>/dev/null; then
        echo -e "${RED}[错误] 未安装qbittorrent-nox，请先执行安装！${NC}"
        return
    fi
    if ! systemctl is-active --quiet "${QBIT_SERVICE}"; then
        echo -e "${YELLOW}[提示] 服务未运行，将启动服务后重置密码...${NC}"
        start_qbit
    fi

    echo -e "${BLUE}[开始] 重置WebUI密码为默认值：${DEFAULT_RESET_PWD}${NC}"
    # 管道传入默认密码重置
    echo -e "${DEFAULT_RESET_PWD}\n${DEFAULT_RESET_PWD}" | qbittorrent-nox --webui-port "${QBIT_PORT}" --change-webui-password
    echo -e "${GREEN}[成功] WebUI密码重置完成，默认密码：${DEFAULT_RESET_PWD}${NC}"
}

# 主菜单
main_menu() {
    clear
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${GREEN}          qBittorrent-nox 管理脚本            ${NC}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e "${BLUE}适配系统：${NC}Debian/Ubuntu/CentOS/RHEL/Fedora (systemd)"
    echo -e "${BLUE}WebUI端口：${NC}${QBIT_PORT} | ${BLUE}默认重置密码：${NC}${DEFAULT_RESET_PWD}"
    echo -e "${GREEN}=============================================${NC}"
    echo -e " 1. 安装qbittorrent-nox"
    echo -e " 2. 启动qbittorrent-nox"
    echo -e " 3. 关闭qbittorrent-nox"
    echo -e " 4. 重启qbittorrent-nox"
    echo -e " 5. 检测服务状态（进程/端口/自启动）"
    echo -e " 6. 开启开机自启动"
    echo -e " 7. 关闭开机自启动"
    echo -e " 8. 自定义修改WebUI密码"
    echo -e " 9. 重置WebUI密码（默认值）"
    echo -e " 0. 退出脚本"
    echo -e "${GREEN}=============================================${NC}"
    read -p "请输入操作编号[0-9]：" OPT

    case $OPT in
        1) install_qbit ;;
        2) start_qbit ;;
        3) stop_qbit ;;
        4) restart_qbit ;;
        5) status_qbit ;;
        6) enable_auto ;;
        7) disable_auto ;;
        8) change_pwd ;;
        9) reset_pwd ;;
        0) echo -e "${GREEN}[退出] 脚本执行完成，再见！${NC}"; exit 0 ;;
        *) echo -e "${RED}[错误] 输入无效，请输入0-9的编号！${NC}" ;;
    esac

    # 执行完操作后停留，按回车返回菜单
    echo -e "\n${YELLOW}[提示] 按回车键返回主菜单...${NC}"
    read -r
    main_menu
}

# 启动主菜单
main_menu
