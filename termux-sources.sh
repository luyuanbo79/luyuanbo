#!/data/data/com.termux/files/usr/bin/bash

# 定义国内源列表，依照用户指定顺序排列
sources=(
    "官方源 (默认)"
    "清华大学源"
    "中国科学技术大学源"
    "阿里云源"
    "腾讯云源"
    "华为云源"
    "网易开源镜像站"
    "重庆大学开源镜像站"
    "浙江大学开源镜像站"
    "东软信息学院镜像站"
    "中国科学院开源镜像站"
    "北京外国语大学镜像站"
    "兰州大学开源镜像站"
    "北京交通大学镜像站"
    "大连理工大学镜像站"
)

# 备份原始源文件
cp /data/data/com.termux/files/usr/etc/apt/sources.list /data/data/com.termux/files/usr/etc/apt/sources.list.bak

# 引导用户选择目标源
select source in "${sources[@]}"; do
    case $source in
        "官方源 (默认)")
            echo "正在恢复官方源..."
            cp /data/data/com.termux/files/usr/etc/apt/sources.list.bak /data/data/com.termux/files/usr/etc/apt/sources.list
            break
            ;;
        "清华大学源") mirror_url="https://mirrors.tuna.tsinghua.edu.cn/termux" ;;
        "中国科学技术大学源") mirror_url="https://mirrors.ustc.edu.cn/termux" ;;
        "阿里云源") mirror_url="https://mirrors.aliyun.com/termux" ;;
        "腾讯云源") mirror_url="https://mirrors.cloud.tencent.com/termux" ;;
        "华为云源") mirror_url="https://repo.huaweicloud.com/termux" ;;
        "网易开源镜像站") mirror_url="https://mirrors.163.com/termux" ;;
        "重庆大学开源镜像站") mirror_url="https://mirrors.cqu.edu.cn/termux" ;;
        "浙江大学开源镜像站") mirror_url="https://mirrors.zju.edu.cn/termux" ;;
        "东软信息学院镜像站") mirror_url="https://mirrors.neusoft.edu.cn/termux" ;;
        "中国科学院开源镜像站") mirror_url="https://mirrors.iscas.ac.cn/termux" ;;
        "北京外国语大学镜像站") mirror_url="https://mirrors.bfsu.edu.cn/termux" ;;
        "兰州大学开源镜像站") mirror_url="https://mirrors.lzu.edu.cn/termux" ;;
        "北京交通大学镜像站") mirror_url="https://mirrors.bjtu.edu.cn/termux" ;;
        "大连理工大学镜像站") mirror_url="https://mirrors.dlut.edu.cn/termux" ;;
        *) echo "无效的选择，请重新输入" && continue ;;
    esac

    echo "正在切换到 ${source}..."
    cat <<EOF > /data/data/com.termux/files/usr/etc/apt/sources.list
deb ${mirror_url}/apt/termux-main stable main
deb ${mirror_url}/apt/termux-root stable main
# 科学源（按需启用）
# deb ${mirror_url}/science science stable
EOF
    break
done

# 更新软件包索引
echo "正在更新软件包列表..."
apt update -y

# 操作完成提示
echo -e "\n源切换已完成！当前日期为：$(date +%Y-%m-%d)"
echo "若出现问题，可通过以下命令恢复官方源："
echo "cp /data/data/com.termux/files/usr/etc/apt/sources.list.bak /data/data/com.termux/files/usr/etc/apt/sources.list"
echo "然后执行 apt update"
