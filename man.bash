#!/bin/bash
# 交互式系统维护脚本
# 功能：备份数据、挂载外接存储、管理 Docker、清理日志、SMB 配置及挂载
# 名称：man.bash

set -euo pipefail

# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# 检查是否以 root 或 sudo 运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户或 sudo 执行此脚本。"
    exit 1
fi

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 收集本次运行中执行的操作
actions=()

# 添加操作到数组
record_action() {
    local action="$1"
    actions+=("$action")
}

# 退出时统一写入一条日志
write_final_log() {
    if [ ${#actions[@]} -gt 0 ]; then
        local log_file="${SCRIPT_DIR}/bash_history.log"
        local timestamp=$(date +%Y-%m-%d-%H:%M)
        local suffix=$(IFS=_ ; echo "${actions[*]}")
        echo "{$timestamp}_${suffix}_manual" >> "$log_file" 2>/dev/null || true
    fi
}

trap write_final_log EXIT

# SMB 相关路径
SMB_CONFIG_DIR="$SCRIPT_DIR/command/mount"
SMB_CONFIG_FILE="$SMB_CONFIG_DIR/smb.conf"
SMB_MOUNT_SCRIPT="$SCRIPT_DIR/command/mount/smb.bash"

# ========== 备份功能 ==========
backup_dockerdb() {
    local backup_script="$SCRIPT_DIR/command/docker_db_backup.bash"
    if [ ! -f "$backup_script" ]; then
        echo -e "${RED}错误：未找到 $backup_script${NC}"
        record_action "backup_dockerdb_failed"
        sleep 2
        return 1
    fi
    echo -e "${GREEN}开始备份 Docker 持久化数据...${NC}"
    bash "$backup_script"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}备份 Docker 数据完成。${NC}"
        record_action "backup_dockerdb"
    else
        echo -e "${RED}备份 Docker 数据失败，请检查错误。${NC}"
        record_action "backup_dockerdb_failed"
    fi
    sleep 2
}

backup_config() {
    local backup_script="$SCRIPT_DIR/command/system_conf_backup.bash"
    if [ ! -f "$backup_script" ]; then
        echo -e "${RED}错误：未找到 $backup_script${NC}"
        record_action "backup_config_failed"
        sleep 2
        return 1
    fi
    echo -e "${GREEN}开始备份本机配置文件...${NC}"
    bash "$backup_script"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}备份配置文件完成。${NC}"
        record_action "backup_config"
    else
        echo -e "${RED}备份配置文件失败，请检查错误。${NC}"
        record_action "backup_config_failed"
    fi
    sleep 2
}

# ========== 挂载外接存储（原有） ==========
mount_storage() {
    echo -e "${GREEN}开始执行挂载外接存储操作...${NC}"
    local mount_dir="$SCRIPT_DIR/command/mount"
    if [ ! -d "$mount_dir" ]; then
        echo -e "${RED}错误：目录 $mount_dir 不存在，请检查。${NC}"
        record_action "mount_storage_failed"
        return 1
    fi
    cd "$mount_dir" || { echo -e "${RED}无法进入 $mount_dir${NC}"; record_action "mount_storage_failed"; return 1; }
    echo "进入目录: $(pwd)"
    if [ ! -f "smb.bash" ]; then
        echo -e "${RED}错误：在 $mount_dir 下未找到 smb.bash 文件。${NC}"
        record_action "mount_storage_failed"
        return 1
    fi
    echo "执行 bash smb.bash ..."
    bash smb.bash
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}挂载命令执行成功。${NC}"
        record_action "mount_storage"
    else
        echo -e "${RED}挂载命令执行失败，请检查错误信息。${NC}"
        record_action "mount_storage_failed"
    fi
    cd - > /dev/null
    sleep 2
}

# ========== Docker 管理 ==========
docker_menu() {
    local docker_compose_dir="$(dirname "$SCRIPT_DIR")/origin_conf"
    if [ ! -d "$docker_compose_dir" ]; then
        echo -e "${RED}错误：Docker Compose 目录不存在: $docker_compose_dir${NC}"
        sleep 3
        return 1
    fi
    if [ ! -f "$docker_compose_dir/docker-compose.yml" ]; then
        echo -e "${RED}错误：在 $docker_compose_dir 下未找到 docker-compose.yml${NC}"
        sleep 3
        return 1
    fi

    while true; do
        echo -e "${BLUE}========== 管理 Docker ==========${NC}"
        echo "1. 一键启动所有容器"
        echo "2. 一键关闭所有容器"
        echo "3. 一键生成所有容器"
        echo "4. 一键删除所有容器"
        echo "5. 一键更新所有容器"
        echo "b. 返回主菜单"
        read -p "请选择 [1-5/b]: " docker_choice
        case $docker_choice in
            1)
                echo -e "${GREEN}正在启动所有容器...${NC}"
                cd "$docker_compose_dir"
                if docker compose start; then
                    record_action "docker_start"
                else
                    record_action "docker_start_failed"
                fi
                cd - > /dev/null
                echo -e "${GREEN}操作完成。${NC}"
                sleep 2
                ;;
            2)
                echo -e "${GREEN}正在关闭所有容器...${NC}"
                cd "$docker_compose_dir"
                if docker compose stop; then
                    record_action "docker_stop"
                else
                    record_action "docker_stop_failed"
                fi
                cd - > /dev/null
                echo -e "${GREEN}操作完成。${NC}"
                sleep 2
                ;;
            3)
                echo -e "${GREEN}正在生成（创建并启动）所有容器...${NC}"
                cd "$docker_compose_dir"
                if docker compose up -d; then
                    record_action "docker_up"
                else
                    record_action "docker_up_failed"
                fi
                cd - > /dev/null
                echo -e "${GREEN}操作完成。${NC}"
                sleep 2
                ;;
            4)
                echo -e "${YELLOW}警告：此操作将删除所有容器（但不会删除镜像和数据卷）。${NC}"
                read -p "确认删除？[y/N]: " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    cd "$docker_compose_dir"
                    if docker compose down; then
                        record_action "docker_down"
                    else
                        record_action "docker_down_failed"
                    fi
                    cd - > /dev/null
                    echo -e "${GREEN}操作完成。${NC}"
                else
                    echo "已取消删除操作。"
                fi
                sleep 2
                ;;
            5)
                echo -e "${GREEN}正在更新所有容器（拉取镜像 + 重新创建）...${NC}"
                cd "$docker_compose_dir"
                if docker compose pull && docker compose up -d; then
                    record_action "docker_update"
                else
                    record_action "docker_update_failed"
                fi
                cd - > /dev/null
                echo -e "${GREEN}操作完成。${NC}"
                sleep 2
                ;;
            b|B)
                break
                ;;
            *)
                echo -e "${RED}无效输入，请重新选择。${NC}"
                sleep 1
                ;;
        esac
    done
}

# ========== 日志清理 ==========
clean_logs() {
    local force_flag="$1"
    local mode_suffix=""
    if [[ "$force_flag" == "-f" ]]; then
        mode_suffix="_force"
    fi

    echo -e "${BLUE}========== 手动清理日志${mode_suffix} ==========${NC}"
    read -p "请输入要保留的天数（例如 180 表示清理超过 180 天的日志）: " days
    if [[ ! "$days" =~ ^[0-9]+$ ]]; then
        echo -e "${RED}错误：请输入有效的数字。${NC}"
        sleep 2
        return 1
    fi

    local clear_script="$SCRIPT_DIR/command/clear_log.bash"
    if [ ! -f "$clear_script" ]; then
        echo -e "${RED}错误：未找到 $clear_script${NC}"
        record_action "clear_log${mode_suffix}_failed"
        sleep 2
        return 1
    fi

    echo -e "${GREEN}开始清理超过 ${days} 天的日志...${NC}"
    bash "$clear_script" $force_flag -t "$days"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}日志清理完成。${NC}"
        record_action "clear_log${mode_suffix}"
    else
        echo -e "${RED}日志清理失败，请检查错误。${NC}"
        record_action "clear_log${mode_suffix}_failed"
    fi
    sleep 2
}

# ========== SMB 配置管理功能 ==========
ensure_smb_config_dir() {
    if [ ! -d "$SMB_CONFIG_DIR" ]; then
        mkdir -p "$SMB_CONFIG_DIR"
        echo -e "${GREEN}创建目录: $SMB_CONFIG_DIR${NC}"
    fi
    if [ ! -f "$SMB_CONFIG_FILE" ]; then
        touch "$SMB_CONFIG_FILE"
        echo -e "${GREEN}创建空配置文件: $SMB_CONFIG_FILE${NC}"
    fi
}

list_smb_configs() {
    ensure_smb_config_dir
    echo -e "${BLUE}当前 SMB 挂载配置（$SMB_CONFIG_FILE）：${NC}"
    if [ ! -s "$SMB_CONFIG_FILE" ]; then
        echo -e "${YELLOW}（配置文件为空）${NC}"
    else
        cat -n "$SMB_CONFIG_FILE"
    fi
    echo ""
}

add_smb_config() {
    ensure_smb_config_dir
    echo -e "${GREEN}===== 新增 SMB 挂载配置 =====${NC}"
    read -p "请输入 SMB 服务器地址和共享名（格式 //IP/共享名）: " server_share
    if [[ ! "$server_share" =~ ^//[^/]+/.+$ ]]; then
        echo -e "${RED}格式错误，请使用 //服务器IP/共享名 格式${NC}"
        return 1
    fi
    read -p "请输入本地挂载点（绝对路径）: " mountpoint
    if [[ ! "$mountpoint" =~ ^/ ]]; then
        echo -e "${RED}挂载点必须是绝对路径${NC}"
        return 1
    fi
    read -p "请输入 SMB 用户名: " username
    read -s -p "请输入 SMB 密码: " password
    echo ""
    # 检查是否已存在相同配置
    if grep -q "^$server_share $mountpoint " "$SMB_CONFIG_FILE" 2>/dev/null; then
        echo -e "${YELLOW}配置已存在，跳过添加。${NC}"
        return 1
    fi
    echo "$server_share $mountpoint $username $password" >> "$SMB_CONFIG_FILE"
    echo -e "${GREEN}已添加配置。${NC}"
    record_action "smb_add"
    echo ""
}

delete_smb_config() {
    ensure_smb_config_dir
    if [ ! -s "$SMB_CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件为空，无配置可删除。${NC}"
        return
    fi
    echo -e "${BLUE}当前 SMB 挂载配置：${NC}"
    cat -n "$SMB_CONFIG_FILE"
    echo ""
    read -p "请输入要删除的行号（输入 0 取消）: " line_num
    if [[ ! "$line_num" =~ ^[0-9]+$ ]] || [ "$line_num" -eq 0 ]; then
        echo -e "${YELLOW}取消删除。${NC}"
        return
    fi
    total_lines=$(wc -l < "$SMB_CONFIG_FILE")
    if [ "$line_num" -lt 1 ] || [ "$line_num" -gt "$total_lines" ]; then
        echo -e "${RED}行号无效（范围 1-$total_lines）${NC}"
        return 1
    fi
    sed -i "${line_num}d" "$SMB_CONFIG_FILE"
    echo -e "${GREEN}已删除第 $line_num 行。${NC}"
    record_action "smb_del"
    echo ""
}

smb_menu() {
    while true; do
        echo -e "${BLUE}========== SMB 挂载参数配置 ==========${NC}"
        echo "1. 查看所有 SMB 挂载配置"
        echo "2. 新增一个 SMB 挂载配置"
        echo "3. 删除一个 SMB 挂载配置"
        echo "b. 返回上级菜单"
        read -p "请选择 [1/2/3/b]: " sub_choice
        case "$sub_choice" in
            1) list_smb_configs ;;
            2) add_smb_config ;;
            3) delete_smb_config ;;
            b|B) break ;;
            *) echo -e "${RED}无效选择${NC}" ;;
        esac
    done
}

# ========== 挂载 SMB 远程目录 ==========
mount_smb_remote() {
    echo -e "${BLUE}========== 挂载 SMB 远程目录 ==========${NC}"
    if [ ! -f "$SMB_MOUNT_SCRIPT" ]; then
        echo -e "${RED}错误: 未找到 $SMB_MOUNT_SCRIPT${NC}"
        echo "请确保 command/mount/smb.bash 脚本存在。"
        record_action "smb_mount_failed"
        return 1
    fi
    local target_dir="$SCRIPT_DIR/command/mount"
    local original_dir=$(pwd)
    echo "切换到目录: $target_dir"
    cd "$target_dir"
    echo "执行: bash smb.bash"
    bash smb.bash
    local ret=$?
    cd "$original_dir"
    if [ $ret -eq 0 ]; then
        echo -e "${GREEN}SMB 挂载脚本执行完成。${NC}"
        record_action "smb_mount"
    else
        echo -e "${RED}SMB 挂载脚本执行失败（退出码: $ret）。${NC}"
        record_action "smb_mount_failed"
    fi
    echo ""
}

# ========== 主菜单 ==========
main_menu() {
    while true; do
        echo -e "${BLUE}========== 系统维护脚本 ==========${NC}"
        echo "1. 备份 Docker 持久化数据"
        echo "2. 备份本机配置文件"
        echo "3. 挂载外接存储"
        echo "4. 管理 Docker"
        echo "5. 配置 SMB 挂载参数"
        echo "6. 挂载 SMB 远程目录"
        echo "7. 手动清理日志"
        echo "8. 手动清理日志（强制模式）"
        echo "e. 退出"
        read -p "请输入选项 [1/2/3/4/5/6/7/8/e]: " main_choice
        case $main_choice in
            1) backup_dockerdb ;;
            2) backup_config ;;
            3) mount_storage ;;
            4) docker_menu ;;
            5) smb_menu ;;
            6) mount_smb_remote ;;
            7) clean_logs "" ;;
            8) clean_logs "-f" ;;
            e|E) echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效输入，请输入 1-8 或 e。${NC}"; sleep 1 ;;
        esac
        echo ""
    done
}

# 启动脚本
main_menu
