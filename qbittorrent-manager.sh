#!/bin/bash

# qBittorrent 安装卸载脚本
# 支持 Debian/Ubuntu 及 RHEL/CentOS/Fedora 系列系统

# 检查是否以root权限运行
if [ "$(id -u)" -ne 0 ]; then
    echo "错误：请使用root权限运行此脚本 (sudo $0)" >&2
    exit 1
fi

# 检测Linux发行版
detect_distro() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$NAME
        VER=$VERSION_ID
    else
        echo "无法检测操作系统版本"
        exit 1
    fi
}

# 安装qBittorrent
install_qbittorrent() {
    echo "正在安装qBittorrent..."
    
    if [[ $OS == *"Ubuntu"* || $OS == *"Debian"* ]]; then
        # Debian/Ubuntu 系列
        apt update -y
        apt install -y qbittorrent-nox
        
        # 创建系统服务
        cat > /etc/systemd/system/qbittorrent.service << EOF
[Unit]
Description=qBittorrent Daemon
After=network.target

[Service]
User=root
Group=root
Type=forking
ExecStart=/usr/bin/qbittorrent-nox -d
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        
        # 启动并设置开机自启
        systemctl daemon-reload
        systemctl start qbittorrent
        systemctl enable qbittorrent
        
    elif [[ $OS == *"CentOS"* || $OS == *"Red Hat"* || $OS == *"Fedora"* ]]; then
        # RHEL/CentOS/Fedora 系列
        if [[ $OS == *"Fedora"* ]]; then
            dnf install -y qbittorrent-nox
        else
            # CentOS/RHEL 需要EPEL源
            yum install -y epel-release
            yum install -y qbittorrent-nox
        fi
        
        # 创建系统服务
        cat > /etc/systemd/system/qbittorrent.service << EOF
[Unit]
Description=qBittorrent Daemon
After=network.target

[Service]
User=root
Group=root
Type=forking
ExecStart=/usr/bin/qbittorrent-nox -d
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
        
        # 启动并设置开机自启
        systemctl daemon-reload
        systemctl start qbittorrent
        systemctl enable qbittorrent
    else
        echo "不支持的操作系统：$OS"
        exit 1
    fi

    echo "qBittorrent 安装完成！"
    echo "默认Web界面地址：http://localhost:8080"
    echo "默认用户名：admin，默认密码：adminadmin"
}

# 卸载qBittorrent
uninstall_qbittorrent() {
    echo "正在卸载qBittorrent..."
    
    # 停止服务并禁用自启
    if systemctl is-active --quiet qbittorrent; then
        systemctl stop qbittorrent
    fi
    systemctl disable qbittorrent 2>/dev/null
    
    # 删除系统服务文件
    rm -f /etc/systemd/system/qbittorrent.service
    systemctl daemon-reload
    
    # 根据不同发行版卸载软件包
    if [[ $OS == *"Ubuntu"* || $OS == *"Debian"* ]]; then
        apt purge -y qbittorrent-nox
        apt autoremove -y
    elif [[ $OS == *"CentOS"* || $OS == *"Red Hat"* || $OS == *"Fedora"* ]]; then
        if [[ $OS == *"Fedora"* ]]; then
            dnf remove -y qbittorrent-nox
        else
            yum remove -y qbittorrent-nox
        fi
    else
        echo "不支持的操作系统：$OS"
        exit 1
    fi

    echo "qBittorrent 卸载完成！"
}

# 显示服务状态
show_status() {
    if systemctl is-active --quiet qbittorrent; then
        echo "qBittorrent 正在运行"
        echo "Web界面地址：http://localhost:8080"
    else
        echo "qBittorrent 未运行"
    fi
}

# 主菜单
main_menu() {
    clear
    echo "================ qBittorrent 管理脚本 ================"
    echo "1. 安装 qBittorrent"
    echo "2. 卸载 qBittorrent"
    echo "3. 启动 qBittorrent"
    echo "4. 停止 qBittorrent"
    echo "5. 重启 qBittorrent"
    echo "6. 查看状态"
    echo "7. 退出"
    echo "======================================================"
    read -p "请选择操作 [1-7]: " choice

    case $choice in
        1) install_qbittorrent ;;
        2) uninstall_qbittorrent ;;
        3) systemctl start qbittorrent; echo "已启动" ;;
        4) systemctl stop qbittorrent; echo "已停止" ;;
        5) systemctl restart qbittorrent; echo "已重启" ;;
        6) show_status ;;
        7) exit 0 ;;
        *) echo "无效选择，请重试"; sleep 2; main_menu ;;
    esac

    read -p "操作完成，按回车键返回菜单..."
    main_menu
}

# 开始执行
detect_distro
echo "检测到操作系统：$OS $VER"
sleep 2
main_menu
