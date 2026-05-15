#!/bin/bash
# ============================================================
# 脚本：input.sh
# 功能：交互式配置向导，预载 config/default.json 中的默认值
#       分为五个部分，支持 special_config(Y/N/D) 和 type(L/H) 校验
#       退出选项为 b (back)
# ============================================================

interrupt_handler() {
    echo -e "\n\n操作已被用户中断，返回主菜单..."
    return 1
}
trap 'interrupt_handler; return 1' INT

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}    交互式配置向导（回车保留默认值）   ${NC}"
echo -e "${GREEN}========================================${NC}"
echo "说明："
echo "  1. 所有配置项均已预载默认值（来自 config/default.json）"
echo "  2. 直接回车使用默认值，输入新值覆盖"
echo "  3. 将配置文件保存为 .json 文件后重新导入方可使用"
echo "  4. 按 Ctrl+C 可随时中断并返回主菜单"
echo -e "${YELLOW}请按 Enter 键继续...${NC}"
read

config_dir="${config_dir:-$(pwd)/config}"
default_json="${config_dir}/default.json"
if [[ ! -f "$default_json" ]]; then
    echo "错误：默认配置文件 $default_json 不存在，请检查。"
    return 1
fi

# 中文注释
get_fallback_comment() {
    local key="$1"
    case "$key" in
        Nas_Hostname) echo "主机名" ;;
        special_config) echo "特殊配置 (Y=Yes, N=No, D=Default 预载值)" ;;
        type) echo "部署类型 (L=Light 轻型, H=Heavy 重型)" ;;
        dockerdb_dir) echo "Docker持久化目录" ;;
        Nas_Admin) echo "管理员用户名" ;;
        Nas_Admin_passwd) echo "管理员密码" ;;
        Nas_Root_passwd) echo "Root密码" ;;
        Mirror) echo "镜像源 (tsinghua/163/aliyun/tencent)" ;;
        Packages_standard) echo "基础软件包（多个用英文逗号隔开）" ;;
        SSH_0) echo "临时SSH端口" ;;
        SSH_1) echo "主SSH端口" ;;
        SSH_2) echo "备SSH端口" ;;
        SMB) echo "SMB端口" ;;
        Nas_User) echo "SMB用户名" ;;
        Nas_User_smbpasswd) echo "SMB密码" ;;
        Name) echo "共享名" ;;
        comment) echo "共享注释" ;;
        path) echo "共享路径" ;;
        public) echo "是否公开 (yes/no)" ;;
        browseable) echo "是否可浏览 (yes/no)" ;;
        writable) echo "是否可写 (yes/no)" ;;
        security) echo "安全模式" ;;
        "guest ok") echo "访客允许 (yes/no)" ;;
        "create mask") echo "创建掩码" ;;
        "directory mask") echo "目录掩码" ;;
        "max connections") echo "最大连接数" ;;
        address) echo "静态IP地址" ;;
        netmask) echo "子网掩码" ;;
        gateway) echo "网关" ;;
        dns-nameservers) echo "DNS服务器" ;;
        filebrowser_dir) echo "FileBrowser 数据目录" ;;
        jellyfin_mapping_1) echo "Jellyfin 映射1 (格式: 宿主机目录:容器目录)" ;;
        jellyfin_mapping_2) echo "Jellyfin 映射2 (直接回车跳过)" ;;
        jellyfin_mapping_3) echo "Jellyfin 映射3 (直接回车跳过)" ;;
        syncthing_mapping_1) echo "Syncthing 映射1 (格式: 宿主机目录:容器目录)" ;;
        syncthing_mapping_2) echo "Syncthing 映射2 (直接回车跳过)" ;;
        syncthing_mapping_3) echo "Syncthing 映射3 (直接回车跳过)" ;;
        qbittorrent_mapping) echo "qBittorrent 卷映射 (格式: 宿主机目录:容器目录)" ;;
        aria2_dir) echo "Aria2 配置/下载目录" ;;
        aria2_passwd) echo "Aria2 密钥 (token)" ;;
        *) echo "$key" ;;
    esac
}

# 从 default.json 提取默认值（安全处理空值）
get_default_value() {
    local key="$1"
    local escaped_key=$(printf '%s\n' "$key" | sed 's/[\[\.\*\^\$]/\\&/g')
    local line=$(grep -E "^\s*\"$escaped_key\"\s*:" "$default_json" | head -1)
    if [[ -z "$line" ]]; then
        echo ""
        return
    fi
    if [[ "$line" =~ :[[:space:]]*\"([^\"]*)\" ]]; then
        echo "${BASH_REMATCH[1]}"
    else
        local value=$(echo "$line" | sed -E 's/.*:[[:space:]]*//;s/[[:space:]]*[,]?[[:space:]]*$//')
        echo "$value"
    fi
}

# 各部分键组
part1_keys=(
    "Nas_Hostname" "special_config" "type" "dockerdb_dir"
    "Nas_Admin" "Nas_Admin_passwd" "Nas_Root_passwd"
)
part2_keys=(
    "Mirror" "Packages_standard" "SSH_0" "SSH_1" "SSH_2" "SMB"
)
part3_keys=(
    "Nas_User" "Nas_User_smbpasswd" "Name" "comment" "path"
    "public" "browseable" "writable" "security" "guest ok"
    "create mask" "directory mask" "max connections"
)
part4_keys=(
    "address" "netmask" "gateway" "dns-nameservers"
)
part5_keys=(
    "filebrowser_dir" 
    "jellyfin_mapping_1" "jellyfin_mapping_2" "jellyfin_mapping_3"
    "syncthing_mapping_1" "syncthing_mapping_2" "syncthing_mapping_3"
    "qbittorrent_mapping"
    "aria2_dir" "aria2_passwd"
)

declare -A user_values

input_part() {
    local title="$1"
    shift
    local keys=("$@")
    echo -e "\n${YELLOW}######## ${title} ########${NC}"
    for key in "${keys[@]}"; do
        default_val=$(get_default_value "$key")
        if [[ -z "$default_val" && "$default_val" != "" ]]; then
            default_val="未设置"
        fi
        comment=$(get_fallback_comment "$key")
        if [[ "$key" == "Packages_standard" ]]; then
            echo -e "${YELLOW}提示：可输入多个软件包，用英文逗号隔开，最后一个不加逗号。${NC}"
        fi
        while true; do
            read -p "请输入 $key ($comment) (默认: $default_val): " input
            if [[ -z "$input" ]]; then
                input="$default_val"
                break
            fi
            if [[ "$key" == "special_config" ]]; then
                if [[ "$input" =~ ^[YNDynd]$ ]]; then
                    input=$(echo "$input" | tr '[:lower:]' '[:upper:]')
                    break
                else
                    echo "错误：special_config 只能为 Y, N 或 D（不区分大小写）"
                    continue
                fi
            elif [[ "$key" == "type" ]]; then
                if [[ "$input" =~ ^[LHlh]$ ]]; then
                    input=$(echo "$input" | tr '[:lower:]' '[:upper:]')
                    break
                else
                    echo "错误：type 只能为 L 或 H（不区分大小写）"
                    continue
                fi
            else
                break
            fi
        done
        user_values["$key"]="$input"
    done
    echo -e "${YELLOW}######## ${title}已完成 ########${NC}"
}

# 执行输入
input_part "系统与用户配置" "${part1_keys[@]}"
input_part "端口、镜像源、基础软件配置" "${part2_keys[@]}"
input_part "SMB共享配置" "${part3_keys[@]}"
input_part "网络信息配置（写死IP）" "${part4_keys[@]}"
input_part "特殊服务配置" "${part5_keys[@]}"

# 后续操作
echo -e "\n${GREEN}所有配置项已收集完成。${NC}"
echo "请选择后续操作："
echo "  s) 保存为 .json 文件（默认保存至 $config_dir）"
echo "  b) 不保存直接退出"
read -p "请选择 [s/b]: " action

# 定义需要导出的合法变量名列表
EXPORT_KEYS=(
    "Nas_Hostname" "special_config" "type" "dockerdb_dir"
    "Nas_Admin" "Nas_Admin_passwd" "Nas_Root_passwd"
    "Mirror" "Packages_standard"
    "SSH_0" "SSH_1" "SSH_2" "SMB"
    "Nas_User" "Nas_User_smbpasswd"
    "filebrowser_dir"
    "jellyfin_mapping_1" "jellyfin_mapping_2" "jellyfin_mapping_3"
    "syncthing_mapping_1" "syncthing_mapping_2" "syncthing_mapping_3"
    "qbittorrent_mapping"
    "aria2_dir" "aria2_passwd"
)

case "$action" in
    s|S)
        while true; do
            read -p "请输入要保存的文件名（必须为 .json 结尾）: " save_filename
            if [[ ! "$save_filename" =~ \.json$ ]]; then
                echo "错误：文件名必须以 .json 结尾，请重新输入。"
            else
                if [[ "$save_filename" == */* ]]; then
                    save_file="$save_filename"
                else
                    save_file="${config_dir}/${save_filename}"
                fi
                mkdir -p "$(dirname "$save_file")"
                break
            fi
        done
        cp "$default_json" "$save_file"
        for key in "${!user_values[@]}"; do
            new_val="${user_values[$key]}"
            new_val_escaped=$(printf '%s\n' "$new_val" | sed -e 's/[\\"]/\\&/g')
            key_escaped=$(printf '%s\n' "$key" | sed -e 's/[\/&]/\\&/g' -e 's/ /\\ /g')
            sed -i -E "s#^(\s*\"$key_escaped\"\s*:\s*)\"[^\"]*\"#\1\"$new_val_escaped\"#" "$save_file"
            sed -i -E "s#^(\s*\"$key_escaped\"\s*:\s*)[0-9]+#\1$new_val_escaped#" "$save_file"
        done
        echo "已保存配置到 $save_file"
        read -p "是否立即使用此配置？(y/n): " use_now
        if [[ "$use_now" =~ ^[Yy]$ ]]; then
            json_file="$save_file"
            json_dir="$(cd "$(dirname "$save_file")" && pwd)"
            for key in "${EXPORT_KEYS[@]}"; do
                if [[ -n "${user_values[$key]}" ]]; then
                    declare -g "$key"="${user_values[$key]}"
                    export "$key"
                fi
            done
            PRESET_IMPORTED=1
            export PRESET_IMPORTED json_file json_dir
            echo "配置已导入，可以继续使用主菜单功能。"
        fi
        ;;
    b|B)
        echo "已退出，未保存任何更改。"
        return 0
        ;;
    *)
        echo "无效选择，退出。"
        return 1
        ;;
esac

trap - INT
return 0
