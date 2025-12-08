#!/bin/bash
set -euo pipefail

# 彩色输出与状态标识
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PLAIN='\033[0m'
SUCCESS="\033[1;32m✔${PLAIN}"
ERROR="\033[1;31m✘${PLAIN}"
TIP="\033[1;44m TIP ${PLAIN}"

# 国内优质 Docker 源列表（优先级排序）
DOCKER_CE_SOURCES=(
    "mirrors.aliyun.com/docker-ce"
    "mirrors.tencent.com/docker-ce"
    "mirrors.huaweicloud.com/docker-ce"
    "mirrors.tuna.tsinghua.edu.cn/docker-ce"
    "mirrors.ustc.edu.cn/docker-ce"
)
# 镜像加速地址（多源冗余，确保可用性）
REGISTRY_MIRRORS=(
    "https://docker.mirrors.aliyun.com"
    "https://mirror.ccs.tencentyun.com"
    "https://dockerproxy.net"
    "https://docker.1panel.live"
    "https://ustc-edu-cn.mirror.aliyuncs.com"
)

# 检查 root 权限
if [ "$(id -u)" -ne 0 ]; then
    echo -e "\n$ERROR ${RED}必须以 root 用户运行！请执行 sudo -i 切换后重试${PLAIN}\n"
    exit 1
fi

# 识别系统发行版与包管理器
get_system_info() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_VERSION=$VERSION_ID
        # 适配衍生系统
        case $OS_ID in
            rocky|almalinux) OS_ID="centos";;
            anolis|opencloudos) OS_ID="centos";;
            openeuler) OS_ID="centos";;
            kali|linuxmint) OS_ID="debian";;
        esac
        # 确定包管理器
        if [[ $OS_ID == "debian" || $OS_ID == "ubuntu" ]]; then
            PM="apt"
        elif [[ $OS_ID == "centos" || $OS_ID == "rhel" ]]; then
            if [[ $OS_VERSION -ge 8 || $OS_ID == "fedora" ]]; then
                PM="dnf"
            else
                PM="yum"
            fi
        fi
    else
        echo -e "\n$ERROR ${RED}不支持的Linux系统${PLAIN}\n"
        exit 1
    fi
    echo -e "$TIP 系统识别：${BLUE}$OS_ID $OS_VERSION${PLAIN}，包管理器：${BLUE}$PM${PLAIN}"
}

# 卸载旧版 Docker 组件
uninstall_old() {
    echo -e "\n${BLUE}=== 清理旧版 Docker 组件 ===${PLAIN}"
    case $PM in
        apt)
            apt remove -y docker docker-engine docker.io containerd runc docker-ce docker-ce-cli >/dev/null 2>&1 || true
            apt autoremove -y >/dev/null 2>&1
            rm -rf /etc/apt/sources.list.d/docker* /var/lib/docker
            ;;
        yum|dnf)
            $PM remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine docker-ce docker-ce-cli >/dev/null 2>&1 || true
            $PM autoremove -y >/dev/null 2>&1
            rm -rf /etc/yum.repos.d/docker* /var/lib/docker
            ;;
    esac
    echo -ee "$SUCCESS 旧版组件清理完成"
}

# 安装依赖包
install_deps() {
    echo -e "\n${BLUE}=== 安装必要依赖 ===${PLAIN}"
    case $PM in
        apt)
            apt update -y >/dev/null 2>&1
            apt install -y ca-certificates curl apt-transport-https software-properties-common >/dev/null 2>&1
            ;;
        yum)
            yum install -y yum-utils device-mapper-persistent-data lvm2 curl >/dev/null 2>&1
            ;;
        dnf)
            dnf install -y dnf-plugins-core curl >/dev/null 2>&1
            ;;
    esac
    echo -e "$SUCCESS 依赖安装完成"
}

# 添加国内 Docker 源
add_docker_source() {
    echo -e "\n${BLUE}=== 配置国内 Docker 源 ===${PLAIN}"
    local DOCKER_SOURCE=${DOCKER_CE_SOURCES[0]}
    case $PM in
        apt)
            # 导入 GPG 密钥
            curl -fsSL "https://${DOCKER_SOURCE}/linux/${OS_ID}/gpg" | gpg --dearmor -o /etc/apt/trusted.gpg.d/docker.gpg >/dev/null 2>&1
            # 添加源配置
            add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://${DOCKER_SOURCE}/linux/${OS_ID} $(lsb_release -cs) stable" >/dev/null 2>&1
            apt update -y >/dev/null 2>&1
            ;;
        yum|dnf)
            $PM config-manager --add-repo "https://${DOCKER_SOURCE}/linux/${OS_ID}/docker-ce.repo" >/dev/null 2>&1
            # 替换源地址（防止默认官方源）
            sed -i "s|download.docker.com|${DOCKER_SOURCE}|g" /etc/yum.repos.d/docker-ce.repo
            $PM makecache fast >/dev/null 2>&1
            ;;
    esac
    echo -e "$SUCCESS 国内源配置完成（使用：${BLUE}${DOCKER_SOURCE}${PLAIN}）"
}

# 安装 Docker 最新版
install_docker() {
    echo -e "\n${BLUE}=== 安装 Docker 引擎 ===${PLAIN}"
    case $PM in
        apt)
            apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
            ;;
        yum|dnf)
            $PM install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null 2>&1
            ;;
    esac
    echo -e "$SUCCESS Docker 引擎安装完成"
}

# 配置服务与镜像加速
config_docker() {
    echo -e "\n${BLUE}=== 配置 Docker 服务 ===${PLAIN}"
    # 启动并设置开机自启
    systemctl daemon-reload
    systemctl start docker
    systemctl enable docker --now >/dev/null 2>&1

    # 备份原有配置（如有）
    if [ -f /etc/docker/daemon.json ]; then
        cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)
        echo -e "$TIP 原有配置已备份为 daemon.json.bak.xxx"
    fi

    # 配置镜像加速与优化参数
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "registry-mirrors": [$(printf '"%s",' "${REGISTRY_MIRRORS[@]}" | sed 's/,$//')],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "overlay2.override_kernel_check": true
}
EOF

    systemctl restart docker
    echo -e "$SUCCESS 镜像加速与服务优化完成"
}

# 验证安装结果
verify_install() {
    echo -e "\n${GREEN}=== Docker 安装完成，验证信息 ===${PLAIN}"
    if docker --version &>/dev/null; then
        echo -e "Docker 版本：$(docker --version)"
    else
        echo -e "$ERROR ${RED}Docker 安装失败${PLAIN}"
        exit 1
    fi

    if docker compose version &>/dev/null; then
        echo -e "Docker Compose 版本：$(docker compose version | awk '{print $4}')"
    else
        echo -e "$YELLOW 警告：Docker Compose 安装异常，可手动安装${PLAIN}"
    fi

    echo -e "镜像加速配置：$(docker info | grep -E 'Registry Mirrors' | cut -d ':' -f 2-)"
    echo -e "\n${GREEN}======================================${PLAIN}"
    echo -e "${GREEN}✅ 安装成功！使用指南：${PLAIN}"
    echo -e "1. 普通用户免 sudo 使用：${BLUE}sudo usermod -aG docker \$USER${PLAIN}（注销重登生效）"
    echo -e "2. 测试命令：${BLUE}docker run hello-world${PLAIN}（正常输出即可用）"
    echo -e "3. 查看状态：${BLUE}systemctl status docker${PLAIN}"
    echo -e "${GREEN}======================================${PLAIN}"
}

# 主执行流程
main() {
    clear
    echo -e "${BLUE}======================================${PLAIN}"
    echo -e "${BLUE}🎯 Linux 全系统 Docker 一键安装脚本${PLAIN}"
    echo -e "${BLUE}📦 支持所有主流发行版，国内源极速安装${PLAIN}"
    echo -e "${BLUE}======================================${PLAIN}"
    get_system_info
    uninstall_old
    install_deps
    add_docker_source
    install_docker
    config_docker
    verify_install
}

main
