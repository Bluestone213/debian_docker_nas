#!/bin/bash

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
# 检查是否以 root 或 sudo 运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户或 sudo 执行此脚本。"
    exit 1
fi

# 检查配置文件是否存在
if [[ ! -f "$CONF_FILE" ]]; then
    echo "错误: 配置文件 $CONF_FILE 不存在！"
    exit 1
fi

# 从 JSON 中提取 dockerdb_dir 的值
backup_dir=$(sed -n 's/.*"dockerdb_dir": "\([^"]*\)".*/\1/p' "$CONF_FILE")
if [[ -z "$backup_dir" ]]; then
    echo "错误: 无法从 $CONF_FILE 中提取 dockerdb_dir"
    exit 1
fi

# 从 JSON 中提取 syncthing_mapping_1 的值
syncthing_map=$(sed -n 's/.*"syncthing_mapping_1": "\([^"]*\)".*/\1/p' "$CONF_FILE")
if [[ -z "$syncthing_map" ]]; then
    echo "错误: 无法从 $CONF_FILE 中提取 syncthing_mapping_1"
    exit 1
fi
# 提取冒号前的本地路径部分，并拼接 /backup
target_dir="${syncthing_map%%:*}/backup"

# 检查目标目录是否存在，若不存在则创建
if [[ ! -d "$target_dir" ]]; then
    mkdir -p "$target_dir"
    echo "创建备份目标目录: $target_dir"
fi

# ==================== Jellyfin 缓存清理（动态路径，默认注释） ====================
# 根据 dockerdb_dir 动态确定 Jellyfin 缓存目录
jellyfin_cache_dir="${backup_dir}/jellyfin/config/metadata/library"
# 如果需要启用 Jellyfin 缓存清理，请取消下面三行的注释
# echo "清理 Jellyfin 缓存文件: ${jellyfin_cache_dir}"
# cd "${jellyfin_cache_dir}" || exit
# find . -name "*" -type f -mtime +7 -delete

# ==================== 执行 Docker 数据备份 ====================
target_file="${HOSTNAME}_database_$(date +%Y%m%d).tar.gz"
target_path="${target_dir}/${target_file}"

echo "开始备份目录: $backup_dir"
echo "打包为: $target_path"
tar -czvf "$target_path" "$backup_dir"

# ==================== 清理旧备份 ====================
# 删除超过3天的备份文件
find "$target_dir" -name "${HOSTNAME}_database_*.tar.gz" -type f -mtime +3 -delete

# ==================== 重启 Docker ====================
echo "重启 Docker 服务..."
systemctl restart docker

echo "Docker 数据备份完成。"
