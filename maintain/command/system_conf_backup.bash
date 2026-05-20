#!/bin/bash
# 检查是否以 root 或 sudo 运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户或 sudo 执行此脚本。"
    exit 1
fi
# ==================== 配置读取 ====================
# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# 向上两级到达项目根目录
PROJECT_ROOT=$(dirname "$(dirname "$SCRIPT_DIR")")
# origin_conf 目录路径
ORIGIN_CONF_DIR="${PROJECT_ROOT}/origin_conf"
# 本机主机名对应的 JSON 文件
HOSTNAME=$(hostname)
CONF_FILE="${ORIGIN_CONF_DIR}/${HOSTNAME}.json"

# 检查配置文件是否存在
if [[ ! -f "$CONF_FILE" ]]; then
    echo "错误: 配置文件 $CONF_FILE 不存在！"
    exit 1
fi

# 从 JSON 中提取 syncthing_mapping_1 的值
syncthing_map=$(sed -n 's/.*"syncthing_mapping_1": "\([^"]*\)".*/\1/p' "$CONF_FILE")
if [[ -z "$syncthing_map" ]]; then
    echo "错误: 无法从 $CONF_FILE 中提取 syncthing_mapping_1"
    exit 1
fi
# 提取冒号前的本地路径部分，并拼接 /backup
backup_dir="${syncthing_map%%:*}/backup"

# 检查目标目录是否存在，若不存在则创建
if [[ ! -d "$backup_dir" ]]; then
    mkdir -p "$backup_dir"
    echo "创建备份目标目录: $backup_dir"
fi

# ==================== 定义备份文件列表 ====================
files=(
    etc/ssh/sshd_config
    etc/apt/sources.list
    etc/apt/sources.list.d
    etc/hostname
    etc/hosts
    etc/resolv.conf
    etc/fstab
    etc/crontab
    etc/docker/daemon.json
    etc/network/interfaces
    etc/samba/smb.conf
)

# 备份文件名
archive_name="${HOSTNAME}_backup_$(date +%Y%m%d).tar.gz"
archive_path="${backup_dir}/${archive_name}"

# ==================== 执行备份 ====================
echo "开始备份系统配置文件..."
echo "打包为: $archive_path"
tar -czvf "$archive_path" -C / "${files[@]}"

# ==================== 清理旧备份 ====================
# 删除超过7天的备份文件
find "$backup_dir" -name "${HOSTNAME}_backup_*.tar.gz" -type f -mtime +7 -delete

echo "系统配置备份完成。"
