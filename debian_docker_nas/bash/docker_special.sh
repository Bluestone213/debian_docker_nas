#!/bin/bash
# ============================================================
# 脚本：docker_special.sh
# 功能：对已生成的 docker-compose.yml 进行特殊配置（静默模式）
# 参数：$1 = compose 文件路径，$2 = special_config（Y/N/D）
# 说明：除非是错误或必要提示，否则不输出过程信息。
#       对于 scrutiny 容器，会输出生成的 collector.yaml 内容及路径。
#       脚本末尾输出最终特殊配置（仅实际部署的服务）。
# ============================================================

set -e

COMPOSE_FILE="$1"
SPECIAL_CONFIG="${2:-N}"

if [[ ! -f "$COMPOSE_FILE" ]]; then
    echo "错误：找不到 docker-compose.yml 文件: $COMPOSE_FILE" >&2
    exit 1
fi

# 存储配置值的变量
FILEBROWSER_DIR=""
JELLYFIN_DIR=""
SYNCTHING_MAPPING_1=""
SYNCTHING_MAPPING_2=""
SYNCTHING_MAPPING_3=""
QBITTORRENT_DIR=""
ARIA2_DIR=""
ARIA2_PASSWD=""

# 标志变量，标记对应服务是否在 compose 文件中出现
HAS_FILEBROWSER=0
HAS_JELLYFIN=0
HAS_SYNCTHING=0
HAS_QBITTORRENT=0
HAS_ARIA2=0
HAS_SCRUTINY=0

# 辅助函数：从 /dev/tty 读取输入（仅在必要时使用）
read_from_tty() {
    local prompt="$1"
    local var_name="$2"
    local input=""
    echo -n "$prompt" > /dev/tty
    read -r input < /dev/tty
    eval "$var_name='$input'"
}

# 辅助函数：处理多输入（逗号分隔），返回多行（用于 jellyfin）
process_multi_input() {
    local prompt="$1"
    local examples="$2"
    echo "$prompt" > /dev/tty
    echo "示例: $examples" > /dev/tty
    local input=""
    read -r input < /dev/tty
    if [[ -z "$input" ]]; then
        return 1
    fi
    IFS=',' read -ra items <<< "$input"
    for item in "${items[@]}"; do
        item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "$item"
    done
    return 0
}

# ==================== 从 JSON 文件的 ###SPECIAL_CONFIG### 段读取配置 ====================
read_special_config_from_json() {
    local json_file_path="$1"
    if [[ -z "$json_file_path" || ! -f "$json_file_path" ]]; then
        echo "警告：未找到 JSON 配置文件 $json_file_path，跳过读取。" >&2
        return 1
    fi
    local block=$(sed -n '/###SPECIAL_CONFIG###/,/###SPECIAL_CONFIG###/p' "$json_file_path" | grep -v '###SPECIAL_CONFIG###' | grep -v '^[[:space:]]*#')
    if [[ -z "$block" ]]; then
        echo "警告：JSON 文件中未找到 ###SPECIAL_CONFIG### 段。" >&2
        return 1
    fi
    while IFS= read -r line; do
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        [[ -z "$line" ]] && continue
        if [[ "$line" =~ ^\"([a-zA-Z0-9_]+)\"[[:space:]]*:[[:space:]]*\"([^\"]*)\"[,]?[[:space:]]*$ ]]; then
            local key="${BASH_REMATCH[1]}"
            local value="${BASH_REMATCH[2]}"
            case "$key" in
                filebrowser_dir)        FILEBROWSER_DIR="$value" ;;
                jellyfin_dir)           JELLYFIN_DIR="$value" ;;
                syncthing_mapping_1)    SYNCTHING_MAPPING_1="$value" ;;
                syncthing_mapping_2)    SYNCTHING_MAPPING_2="$value" ;;
                syncthing_mapping_3)    SYNCTHING_MAPPING_3="$value" ;;
                qbittorrent_dir)        QBITTORRENT_DIR="$value" ;;
                aria2_dir)              ARIA2_DIR="$value" ;;
                aria2_passwd)           ARIA2_PASSWD="$value" ;;
            esac
        fi
    done <<< "$block"
}

# ==================== 交互式补全缺失的配置（仅 N 模式使用） ====================
interactive_fill_missing() {
    if [[ -z "$FILEBROWSER_DIR" ]]; then
        read_from_tty "请输入 filebrowser 根目录（绝对路径）: " FILEBROWSER_DIR
    fi
    if [[ -z "$JELLYFIN_DIR" ]]; then
        echo "请输入 jellyfin 媒体目录（多个用英文逗号隔开，如 /mnt/media1,/mnt/media2）"
        JELLYFIN_DIR=$(process_multi_input "请输入: " "/mnt/media1,/mnt/media2" 2>/dev/null || echo "")
    fi
    if [[ -z "$SYNCTHING_MAPPING_1" ]]; then
        read_from_tty "请输入 syncthing 映射1（格式 /host:/container）: " SYNCTHING_MAPPING_1
    fi
    if [[ -z "$SYNCTHING_MAPPING_2" ]]; then
        read_from_tty "请输入 syncthing 映射2（直接回车跳过）: " SYNCTHING_MAPPING_2
    fi
    if [[ -z "$SYNCTHING_MAPPING_3" ]]; then
        read_from_tty "请输入 syncthing 映射3（直接回车跳过）: " SYNCTHING_MAPPING_3
    fi
    if [[ -z "$QBITTORRENT_DIR" ]]; then
        read_from_tty "请输入 qbittorrent 下载目录（绝对路径）: " QBITTORRENT_DIR
    fi
    if [[ -z "$ARIA2_DIR" ]]; then
        read_from_tty "请输入 aria2 下载目录（绝对路径）: " ARIA2_DIR
    fi
    if [[ -z "$ARIA2_PASSWD" ]]; then
        read_from_tty "请输入 aria2 RPC 密钥（不能为空）: " ARIA2_PASSWD
        while [[ -z "$ARIA2_PASSWD" ]]; do
            echo "错误：密码不能为空。" >&2
            read_from_tty "请重新输入 aria2 RPC 密钥: " ARIA2_PASSWD
        done
    fi
}

# ==================== 根据模式获取配置初始值 ====================
case "$SPECIAL_CONFIG" in
    D)
        DEFAULT_JSON="${config_dir:-$(pwd)/config}/default.json"
        read_special_config_from_json "$DEFAULT_JSON" >/dev/null 2>&1
        if [[ -z "$ARIA2_PASSWD" ]]; then
            echo "警告：配置中 aria2_passwd 为空，请输入。" >&2
            read_from_tty "请输入 aria2 RPC 密钥: " ARIA2_PASSWD
            while [[ -z "$ARIA2_PASSWD" ]]; do
                echo "错误：密码不能为空。" >&2
                read_from_tty "请重新输入 aria2 RPC 密钥: " ARIA2_PASSWD
            done
        fi
        ;;
    Y)
        if [[ -z "$json_file" ]]; then
            echo "错误：模式 Y 需要 json_file 环境变量，但未设置。" >&2
            exit 1
        fi
        read_special_config_from_json "$json_file" >/dev/null 2>&1
        if [[ -z "$ARIA2_PASSWD" ]]; then
            echo "警告：配置中 aria2_passwd 为空，请输入。" >&2
            read_from_tty "请输入 aria2 RPC 密钥: " ARIA2_PASSWD
            while [[ -z "$ARIA2_PASSWD" ]]; do
                echo "错误：密码不能为空。" >&2
                read_from_tty "请重新输入 aria2 RPC 密钥: " ARIA2_PASSWD
            done
        fi
        ;;
    N)
        interactive_fill_missing
        ;;
    *)
        echo "错误：无效的 special_config 值 '$SPECIAL_CONFIG'，应为 Y/N/D。" >&2
        exit 1
        ;;
esac

# 构建 qbittorrent 映射字符串（格式：主机目录:容器内相同目录）
QBITTORRENT_MAPPING=""
if [[ -n "$QBITTORRENT_DIR" ]]; then
    QBITTORRENT_MAPPING="$QBITTORRENT_DIR:$QBITTORRENT_DIR"
fi

# ==================== 添加卷映射到 compose 文件（静默执行） ====================
add_line_after() {
    local line_num="$1"
    local content="$2"
    sed -i "${line_num}a\\      ${content}" "$COMPOSE_FILE"
}

LINE_NUM=0
while IFS= read -r line <&3; do
    LINE_NUM=$((LINE_NUM + 1))
    if [[ "$line" =~ ^[[:space:]]+image:[[:space:]]+(.+)$ ]]; then
        IMAGE_NAME="${BASH_REMATCH[1]}"
        IMAGE_NAME=$(echo "$IMAGE_NAME" | sed 's/^"//;s/"$//')

        # 1. filebrowser
        if [[ "$IMAGE_NAME" == *"filebrowser/filebrowser"* ]]; then
            HAS_FILEBROWSER=1
            for ((i=LINE_NUM+1; i<=LINE_NUM+10; i++)); do
                vol_line=$(sed -n "${i}p" "$COMPOSE_FILE")
                if [[ "$vol_line" =~ ^[[:space:]]+volumes:[[:space:]]*$ ]]; then
                    add_line_after "$i" "- $FILEBROWSER_DIR:/srv"
                    break
                fi
            done
        fi

        # 2. jellyfin
        if [[ "$IMAGE_NAME" == *"jellyfin/jellyfin"* ]]; then
            HAS_JELLYFIN=1
            for ((i=LINE_NUM+1; i<=LINE_NUM+10; i++)); do
                vol_line=$(sed -n "${i}p" "$COMPOSE_FILE")
                if [[ "$vol_line" =~ ^[[:space:]]+volumes:[[:space:]]*$ ]]; then
                    IFS=',' read -ra dirs <<< "$JELLYFIN_DIR"
                    for dir in "${dirs[@]}"; do
                        dir=$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                        add_line_after "$i" "- $dir:/$dir"
                    done
                    break
                fi
            done
        fi

        # 3. syncthing
        if [[ "$IMAGE_NAME" == *"linuxserver/syncthing"* ]]; then
            HAS_SYNCTHING=1
            for ((i=LINE_NUM+1; i<=LINE_NUM+10; i++)); do
                vol_line=$(sed -n "${i}p" "$COMPOSE_FILE")
                if [[ "$vol_line" =~ ^[[:space:]]+volumes:[[:space:]]*$ ]]; then
                    for map in "$SYNCTHING_MAPPING_1" "$SYNCTHING_MAPPING_2" "$SYNCTHING_MAPPING_3"; do
                        if [[ -n "$map" ]]; then
                            add_line_after "$i" "- $map"
                        fi
                    done
                    break
                fi
            done
        fi

        # 4. qbittorrent
        if [[ "$IMAGE_NAME" == *"linuxserver/qbittorrent"* ]]; then
            HAS_QBITTORRENT=1
            # 仅当映射字符串非空时才添加卷
            if [[ -n "$QBITTORRENT_MAPPING" ]]; then
                for ((i=LINE_NUM+1; i<=LINE_NUM+15; i++)); do
                    vol_line=$(sed -n "${i}p" "$COMPOSE_FILE")
                    if [[ "$vol_line" =~ ^[[:space:]]+volumes:[[:space:]]*$ ]]; then
                        add_line_after "$i" "- $QBITTORRENT_MAPPING"
                        break
                    fi
                done
            fi
        fi

        # 5. aria2
        if [[ "$IMAGE_NAME" == *"superng6/aria2"* ]]; then
            HAS_ARIA2=1
            # 修改 SECRET
            for ((i=LINE_NUM+1; i<=LINE_NUM+10; i++)); do
                secret_line=$(sed -n "${i}p" "$COMPOSE_FILE")
                if [[ "$secret_line" =~ ^[[:space:]]+-[[:space:]]*SECRET= ]]; then
                    sed -i "${i}s/SECRET=[^[:space:]]*/SECRET=${ARIA2_PASSWD}/" "$COMPOSE_FILE"
                    break
                fi
            done
            # 添加下载路径 volumes
            for ((i=LINE_NUM+1; i<=LINE_NUM+20; i++)); do
                vol_line=$(sed -n "${i}p" "$COMPOSE_FILE")
                if [[ "$vol_line" =~ ^[[:space:]]+volumes:[[:space:]]*$ ]]; then
                    add_line_after "$i" "- $ARIA2_DIR:/downloads"
                    break
                fi
            done
        fi

        # 6. scrutiny（修改：寻找 devices: 行，最多20行）
        if [[ "$IMAGE_NAME" == *"ghcr.io/analogj/scrutiny:master-omnibus"* ]]; then
            HAS_SCRUTINY=1
            db_dir="${dockerdb_dir:-/mnt/database}"
            scrutiny_dir="${db_dir}/scrutiny"
            mkdir -p "$scrutiny_dir"
            collector_yaml="${scrutiny_dir}/collector.yaml"

            # 获取所有物理磁盘（排除 loop、rom 等）
            disk_list=$(lsblk -d -o NAME,TYPE --noheadings 2>/dev/null | grep -E ' disk$' | awk '{print $1}' | grep -v -E '^(loop|sr[0-9]+|fd[0-9]+)$')
            if [[ -z "$disk_list" ]]; then
                echo "警告：未检测到物理磁盘，scrutiny 的 devices 列表将为空。" >&2
            fi

            # 生成 collector.yaml
            echo "devices:" > "$collector_yaml"
            for disk in $disk_list; do
                if [[ "$disk" =~ ^nvme[0-9]+n[0-9]+$ ]]; then
                    device_type="nvme"
                else
                    device_type="sat"
                fi
                echo "  - device: /dev/$disk" >> "$collector_yaml"
                echo "    type: '$device_type'" >> "$collector_yaml"
            done

            # 在 compose 文件的 scrutiny 服务中查找 devices: 行（最多20行）
            devices_found=0
            for ((i=LINE_NUM+1; i<=LINE_NUM+20; i++)); do
                dev_line=$(sed -n "${i}p" "$COMPOSE_FILE")
                if [[ "$dev_line" =~ ^[[:space:]]+devices:[[:space:]]*$ ]]; then
                    devices_found=1
                    for disk in $disk_list; do
                        add_line_after "$i" "- /dev/$disk:/dev/$disk"
                    done
                    break
                fi
            done
            if [[ $devices_found -eq 0 ]]; then
                echo "警告：在 scrutiny 服务中未找到 devices: 定义，无法添加磁盘设备映射。" >&2
            fi
        fi
    fi
done 3< "$COMPOSE_FILE"

# ==================== 输出最终特殊配置（仅显示实际部署的服务） ====================
echo "最终特殊配置（仅显示已部署的服务）："
[[ $HAS_FILEBROWSER -eq 1 ]] && echo "  filebrowser 根目录: ${FILEBROWSER_DIR:-无}"
[[ $HAS_JELLYFIN -eq 1 ]] && echo "  jellyfin 媒体目录: ${JELLYFIN_DIR:-无}"
if [[ $HAS_SYNCTHING -eq 1 ]]; then
    echo "  syncthing 映射1: ${SYNCTHING_MAPPING_1:-无}"
    echo "  syncthing 映射2: ${SYNCTHING_MAPPING_2:-无}"
    echo "  syncthing 映射3: ${SYNCTHING_MAPPING_3:-无}"
fi
[[ $HAS_QBITTORRENT -eq 1 ]] && echo "  qbittorrent 映射: ${QBITTORRENT_MAPPING:-无}"
if [[ $HAS_ARIA2 -eq 1 ]]; then
    echo "  aria2 下载目录: ${ARIA2_DIR:-无}"
    echo "  aria2 RPC 密钥: ${ARIA2_PASSWD:-无}"
fi

# 如果处理了 scrutiny，输出 collector.yaml 内容及存放位置
if [[ $HAS_SCRUTINY -eq 1 ]]; then
    db_dir="${dockerdb_dir:-/mnt/database}"
    scrutiny_dir="${db_dir}/scrutiny"
    collector_yaml="${scrutiny_dir}/collector.yaml"
    if [[ -f "$collector_yaml" ]]; then
        echo
        echo "已生成 scrutiny 配置文件: $collector_yaml"
        echo "内容如下："
        cat "$collector_yaml"
    else
        echo "警告：未能生成 $collector_yaml" >&2
    fi
fi

echo
echo "特定容器参数处理完成"
exit 0
