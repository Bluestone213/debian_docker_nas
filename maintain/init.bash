#!/bin/bash
# init.bash - 初始化维护脚本
# 功能：配置定时任务、软连接开机自启、docker compose 环境、SMB 挂载配置及挂载执行
# 用法：sudo bash init.bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
AUTO_SCRIPT="$SCRIPT_DIR/auto.bash"
SMB_CONFIG_DIR="$SCRIPT_DIR/command/mount"
SMB_CONFIG_FILE="$SMB_CONFIG_DIR/smb.conf"
SMB_MOUNT_SCRIPT="$SCRIPT_DIR/command/mount/smb.bash"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# 收集本次运行中执行的操作（成功或失败）
actions=()

# 添加操作到数组（不立即写日志）
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
        echo "{$timestamp}_${suffix}_init" >> "$log_file" 2>/dev/null || true
    fi
}

# 捕获 EXIT 信号（正常退出或 Ctrl+C）
trap write_final_log EXIT

# 检查是否以 root 或 sudo 运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户或 sudo 执行此脚本。"
    exit 1
fi

if [ ! -f "$AUTO_SCRIPT" ]; then
    echo -e "${RED}错误: 未找到 $AUTO_SCRIPT${NC}"
    exit 1
fi
chmod +x "$AUTO_SCRIPT"

# ========== 解析小时和日期 ==========
parse_hour() {
    local hour_val=""
    local line_num=$(grep -n "mount_nightly" "$AUTO_SCRIPT" | head -1 | cut -d: -f1)
    if [[ -n "$line_num" ]]; then
        hour_val=$(sed -n "1,$line_num p" "$AUTO_SCRIPT" | tac | grep -E '\[[[:space:]]*"\$hour"[[:space:]]*-eq[[:space:]]*[0-9]+' | head -1 | sed -n 's/.*-eq[[:space:]]*\([0-9]\+\).*/\1/p')
    fi
    if [[ -z "$hour_val" ]]; then
        hour_val=$(grep -E 'elif[[:space:]]+\[[[:space:]]*"\$hour"[[:space:]]*-eq[[:space:]]*[0-9]+' "$AUTO_SCRIPT" | head -1 | sed -n 's/.*-eq[[:space:]]*\([0-9]\+\).*/\1/p')
    fi
    if [[ -z "$hour_val" ]]; then
        hour_val=$(grep -E '\[[[:space:]]*"\$hour"[[:space:]]*-eq[[:space:]]*[0-9]+' "$AUTO_SCRIPT" | tail -1 | sed -n 's/.*-eq[[:space:]]*\([0-9]\+\).*/\1/p')
    fi
    if [[ -z "$hour_val" ]]; then
        echo -e "${YELLOW}无法自动解析挂载任务的小时，请手动输入。${NC}"
        read -e -p "请输入小时（0-23，默认 2）: " input
        hour_val=${input:-2}
    fi
    if [[ "$hour_val" -lt 0 || "$hour_val" -gt 23 ]]; then
        echo -e "${RED}小时范围错误，使用默认值 2${NC}"
        hour_val=2
    fi
    echo "$hour_val"
}

parse_day() {
    local day_val=""
    local line_num=$(grep -n "clear_log" "$AUTO_SCRIPT" | head -1 | cut -d: -f1)
    if [[ -n "$line_num" ]]; then
        day_val=$(sed -n "1,$line_num p" "$AUTO_SCRIPT" | tac | grep -E '\[[[:space:]]*"\$day"[[:space:]]*-eq[[:space:]]*[0-9]+' | head -1 | sed -n 's/.*-eq[[:space:]]*\([0-9]\+\).*/\1/p')
    fi
    if [[ -z "$day_val" ]]; then
        day_val=$(grep -E '\[[[:space:]]*"\$day"[[:space:]]*-eq[[:space:]]*[0-9]+' "$AUTO_SCRIPT" | head -1 | sed -n 's/.*-eq[[:space:]]*\([0-9]\+\).*/\1/p')
    fi
    if [[ -z "$day_val" ]]; then
        echo -e "${YELLOW}无法自动解析日志清理的日期，请手动输入。${NC}"
        read -e -p "请输入日期（1-31，默认 1）: " input
        day_val=${input:-1}
    fi
    if [[ "$day_val" -lt 1 || "$day_val" -gt 31 ]]; then
        echo -e "${RED}日期范围错误，使用默认值 1${NC}"
        day_val=1
    fi
    echo "$day_val"
}

TARGET_HOUR=$(parse_hour)
TARGET_DAY=$(parse_day)

# ========== 读取 JSON 配置 ==========
ORIGIN_CONF_DIR="$(dirname "$SCRIPT_DIR")/origin_conf"
HOSTNAME=$(hostname)
CONF_FILE="$ORIGIN_CONF_DIR/${HOSTNAME}.json"

if [ ! -f "$CONF_FILE" ]; then
    echo -e "${RED}错误: 配置文件 $CONF_FILE 不存在${NC}"
    exit 1
fi

get_json_value() {
    sed -n 's/.*"'"$1"'": "\([^"]*\)".*/\1/p' "$CONF_FILE" | head -1
}

NAS_ADMIN=$(get_json_value "Nas_Admin")
DOCKERDB_DIR=$(get_json_value "dockerdb_dir")
SYNCTHING_MAP=$(get_json_value "syncthing_mapping_1")
SYNCTHING_DIR="${SYNCTHING_MAP%%:*}"

DATA_DIR=$(sed -n '/###SMB_CONFIG###/,/###SMB_CONFIG###/p' "$CONF_FILE" | grep '"path":' | head -1 | sed 's/.*"path": "\([^"]*\)".*/\1/')
if [ -z "$DATA_DIR" ]; then
    DATA_DIR="/mnt/data"
fi

if [ -z "$NAS_ADMIN" ] || [ -z "$DOCKERDB_DIR" ] || [ -z "$SYNCTHING_DIR" ]; then
    echo -e "${RED}错误: JSON 文件缺少必要字段（Nas_Admin, dockerdb_dir, syncthing_mapping_1）${NC}"
    exit 1
fi

ADMIN_HOME=$(getent passwd "$NAS_ADMIN" | cut -d: -f6)
if [ ! -d "$ADMIN_HOME" ]; then
    echo -e "${RED}错误: 用户 $NAS_ADMIN 的家目录不存在${NC}"
    exit 1
fi

BASH_DIR="$DOCKERDB_DIR/bash"
CREATE_BASH_LINK=false
if [ -d "$BASH_DIR" ]; then
    CREATE_BASH_LINK=true
fi

# ========== 定时任务管理 ==========
CRON_REBOOT="@reboot $AUTO_SCRIPT"
CRON_DAILY="5 $TARGET_HOUR * * * $AUTO_SCRIPT"
CRON_MONTHLY="5 12 $TARGET_DAY * * $AUTO_SCRIPT"
CRON_TEMP=$(mktemp)
crontab -l 2>/dev/null > "$CRON_TEMP" || true

show_current() {
    echo -e "${BLUE}当前 crontab 中与 auto.bash 相关的条目：${NC}"
    local found=0
    while IFS= read -r line; do
        if [[ "$line" == *"$AUTO_SCRIPT"* ]] && [[ "$line" != \#* ]]; then
            echo "  $line"
            found=1
        fi
    done < "$CRON_TEMP"
    if [ $found -eq 0 ]; then
        echo -e "  ${YELLOW}（无相关条目）${NC}"
    fi
    echo ""
}

add_or_update() {
    echo -e "${GREEN}正在配置 crontab 条目...${NC}"
    sed -i "\#$AUTO_SCRIPT#d" "$CRON_TEMP"
    echo "$CRON_REBOOT" >> "$CRON_TEMP"
    echo "$CRON_DAILY" >> "$CRON_TEMP"
    echo "$CRON_MONTHLY" >> "$CRON_TEMP"
    crontab "$CRON_TEMP"
    echo -e "${GREEN}已添加/更新以下条目：${NC}"
    echo "  $CRON_REBOOT"
    echo "  $CRON_DAILY"
    echo "  $CRON_MONTHLY"
    record_action "cron_add_update"
}

delete_cron_entries() {
    echo -e "${YELLOW}正在删除所有包含 $AUTO_SCRIPT 的 crontab 条目...${NC}"
    sed -i "\#$AUTO_SCRIPT#d" "$CRON_TEMP"
    crontab "$CRON_TEMP"
    echo -e "${GREEN}已删除。${NC}"
    record_action "cron_delete"
}

# ========== 软连接管理 ==========
create_symlinks() {
    echo -e "${BLUE}========== 创建软连接脚本并设置开机自启 ==========${NC}"
    local command_dir="$SCRIPT_DIR/command"
    mkdir -p "$command_dir"
    local lns_script="$command_dir/lns.bash"

    cat > "$lns_script" <<EOF
#!/bin/bash
# 自动创建维护所需的软连接（开机时由 crontab 调用）
ADMIN_HOME="$ADMIN_HOME"

links=(
    "$DOCKERDB_DIR:docker_db"
    "$DATA_DIR:data"
    "$SYNCTHING_DIR:syncthing"
    "$SCRIPT_DIR:maintain"
EOF
    if [ "$CREATE_BASH_LINK" = true ]; then
        cat >> "$lns_script" <<EOF
    "$BASH_DIR:bash"
EOF
    fi

    cat >> "$lns_script" <<EOF
)

for item in "\${links[@]}"; do
    target="\${item%%:*}"
    link_name="\${item##*:}"
    link_path="\$ADMIN_HOME/\$link_name"
    ln -sfn "\$target" "\$link_path"
    echo "已创建/更新: \$link_path -> \$target"
done
EOF

    chmod +x "$lns_script"
    echo -e "${GREEN}已生成 $lns_script${NC}"

    local reboot_line="@reboot $lns_script"
    local current_cron=$(crontab -l 2>/dev/null || true)
    if echo "$current_cron" | grep -Fq "$reboot_line"; then
        echo -e "${YELLOW}开机自启条目已存在，跳过。${NC}"
    else
        (echo "$current_cron"; echo "$reboot_line") | crontab -
        echo -e "${GREEN}已添加开机自启: $reboot_line${NC}"
    fi

    bash "$lns_script"
    echo ""
    record_action "create_symlinks"
}

delete_symlinks() {
    echo -e "${BLUE}========== 删除软连接并禁止开机自动创建 ==========${NC}"
    local command_dir="$SCRIPT_DIR/command"
    local lns_script="$command_dir/lns.bash"

    if [ -f "$lns_script" ]; then
        rm -f "$lns_script"
        echo -e "${GREEN}已删除 $lns_script${NC}"
    else
        echo -e "${YELLOW}软连接脚本不存在，跳过删除。${NC}"
    fi

    local reboot_line="@reboot $lns_script"
    local current_cron=$(crontab -l 2>/dev/null || true)
    if echo "$current_cron" | grep -Fq "$reboot_line"; then
        local new_cron=$(echo "$current_cron" | grep -Fv "$reboot_line")
        echo "$new_cron" | crontab -
        echo -e "${GREEN}已从 crontab 移除开机自启条目。${NC}"
    else
        echo -e "${YELLOW}未找到开机自启条目，无需移除。${NC}"
    fi

    local links_to_delete=("docker_db" "data" "syncthing" "maintain")
    if [ "$CREATE_BASH_LINK" = true ]; then
        links_to_delete+=("bash")
    fi
    for link in "${links_to_delete[@]}"; do
        link_path="$ADMIN_HOME/$link"
        if [ -L "$link_path" ]; then
            rm -f "$link_path"
            echo -e "${GREEN}已删除软连接: $link_path${NC}"
        elif [ -e "$link_path" ]; then
            echo -e "${YELLOW}$link_path 存在但不是软连接，跳过删除。${NC}"
        fi
    done
    echo -e "${GREEN}软连接清理完成。${NC}"
    echo ""
    record_action "delete_symlinks"
}

# ========== Docker Compose 环境配置 ==========
setup_docker_compose() {
    echo -e "${BLUE}========== 配置 docker compose 环境 ==========${NC}"
    local compose_file="$(dirname "$SCRIPT_DIR")/origin_conf/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        echo -e "${RED}错误: 未找到 docker-compose.yml 文件 ($compose_file)${NC}"
        return 1
    fi
    local bashrc="$ADMIN_HOME/.bashrc"
    local export_line="export COMPOSE_FILE=\"$compose_file\""
    if grep -Fq "$export_line" "$bashrc"; then
        echo -e "${YELLOW}已在 $bashrc 中找到 COMPOSE_FILE 配置，跳过。${NC}"
    else
        echo "" >> "$bashrc"
        echo "# Added by init.bash for docker compose" >> "$bashrc"
        echo "$export_line" >> "$bashrc"
        echo -e "${GREEN}已添加 $export_line 到 $bashrc${NC}"
    fi

    su - "$NAS_ADMIN" -c "source ~/.bashrc" 2>/dev/null || true
    echo -e "${GREEN}已为 $NAS_ADMIN 用户加载环境变量（新终端会自动生效）。${NC}"
    echo ""
    record_action "docker_compose_setup"
}

# ========== SMB 配置管理 ==========
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
    read -e -p "请输入 SMB 服务器地址和共享名（格式 //IP/共享名）: " server_share
    if [[ ! "$server_share" =~ ^//[^/]+/.+$ ]]; then
        echo -e "${RED}格式错误，请使用 //服务器IP/共享名 格式${NC}"
        return 1
    fi
    read -e -p "请输入本地挂载点（绝对路径）: " mountpoint
    if [[ ! "$mountpoint" =~ ^/ ]]; then
        echo -e "${RED}挂载点必须是绝对路径${NC}"
        return 1
    fi
    read -e -p "请输入 SMB 用户名: " username
    read -e -s -p "请输入 SMB 密码: " password
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
    read -e -p "请输入要删除的行号（输入 0 取消）: " line_num
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
        echo -e "${BLUE}========== SMB 挂载配置管理 ==========${NC}"
        echo "1. 查看所有 SMB 挂载配置"
        echo "2. 新增一个 SMB 挂载配置"
        echo "3. 删除一个 SMB 挂载配置"
        echo "b. 返回上级菜单"
        read -e -p "请选择 [1/2/3/b]: " sub_choice
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
    local target_dir="$SCRIPT_DIR/command/mount/"
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
        echo -e "${BLUE}========== 初始化维护脚本 ==========${NC}"
        echo "1. 查看当前定时任务"
        echo "2. 添加/更新定时自动维护"
        echo "3. 删除定时自动维护"
        echo "4. 创建软连接脚本并设置开机自启"
        echo "5. 删除软连接并禁止开机自动创建"
        echo "6. 配置 docker compose 环境变量"
        echo "7. 配置 SMB 挂载参数"
        echo "8. 挂载 SMB 远程目录"
        echo "e. 退出"
        read -e -p "请选择 [1/2/3/4/5/6/7/8/e]: " choice
        case $choice in
            1) show_current ;;
            2) add_or_update ;;
            3) delete_cron_entries ;;
            4) create_symlinks ;;
            5) delete_symlinks ;;
            6) setup_docker_compose ;;
            7) smb_menu ;;
            8) mount_smb_remote ;;
            e|E) rm -f "$CRON_TEMP"; echo -e "${GREEN}再见！${NC}"; exit 0 ;;
            *) echo -e "${RED}无效输入，请重新选择。${NC}" ;;
        esac
        echo ""
    done
}

main_menu
