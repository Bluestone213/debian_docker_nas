#!/bin/bash
# ============================================================
# 脚本功能：配置 Samba 共享
#   1. 检测 Samba 是否安装（未安装则退出）
#   2. 从配置中提取 Nas_User 和密码，创建系统用户并设置 smb 密码
#   3. 检测防火墙 445 端口，若未开放则自动开放（仅限局域网）
#   4. 从 ###SMB_CONFIG### 段生成 /etc/samba/smb.conf，
#      并自动将 valid users 设置为 Nas_User 的值
#   5. 设置共享目录所有权和权限（跳过 Manage 子目录）
# 用法：sudo ./js2smb.sh --config.json
# ============================================================

set -e

# 检查参数
if [[ $# -ne 1 || ! "$1" =~ ^-- ]]; then
    echo "用法: $0 --配置文件.json"
    echo "示例: $0 --config.json"
    exit 1
fi

INPUT_FILE="${1#--}"
if [ ! -f "$INPUT_FILE" ]; then
    echo "错误: 找不到文件 $INPUT_FILE"
    exit 1
fi

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行: sudo $0 --$INPUT_FILE"
    exit 1
fi

# ==================== 1. 检测 Samba 是否安装 ====================
if ! command -v smbd &> /dev/null && ! dpkg -l samba 2>/dev/null | grep -q "^ii"; then
    echo "错误: Samba 未安装。请先安装 Samba（例如 apt install samba）后再运行此脚本。"
    exit 1
fi
echo "Samba 已安装，继续配置。"

# ==================== 2. 提取 Nas_User 和密码（从全局或 ###SMB_USER### 段） ====================
# 优先从 ###SMB_USER### 段中提取，如果不存在则从全局查找
TEMP_USER=$(mktemp)
sed -n '/###SMB_USER###/,/###SMB_USER###/p' "$INPUT_FILE" | \
    grep -v '###SMB_USER###' | \
    grep -v '^\s*#' | \
    grep -v '^\s*$' > "$TEMP_USER"

if [ -s "$TEMP_USER" ]; then
    # 从段中解析 Nas_User 和 Nas_User_smbpasswd
    while IFS= read -r line; do
        key=$(echo "$line" | sed -E 's/^[[:space:]]*["“]([^"“”]+)["“”][[:space:]]*:.*$/\1/')
        value=$(echo "$line" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/')
        case "$key" in
            Nas_User) NAS_USER="$value" ;;
            Nas_User_smbpasswd) SMB_PASS="$value" ;;
        esac
    done < "$TEMP_USER"
fi
rm -f "$TEMP_USER"

# 如果段中没有找到，则从全局查找
if [ -z "$NAS_USER" ]; then
    NAS_USER_LINE=$(grep -E '["“]Nas_User["”][[:space:]]*:' "$INPUT_FILE" | head -1)
    if [ -n "$NAS_USER_LINE" ]; then
        NAS_USER=$(echo "$NAS_USER_LINE" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]+)["“”]?.*/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
fi

if [ -z "$NAS_USER" ]; then
    echo "错误: 在配置文件中找不到 \"Nas_User\": \"...\" 的配置，无法继续"
    exit 1
fi

if [ -z "$SMB_PASS" ]; then
    SMB_PASS_LINE=$(grep -E '["“]Nas_User_smbpasswd["”][[:space:]]*:' "$INPUT_FILE" | head -1)
    if [ -n "$SMB_PASS_LINE" ]; then
        SMB_PASS=$(echo "$SMB_PASS_LINE" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]+)["“”]?.*/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    fi
fi

if [ -z "$SMB_PASS" ]; then
    echo "错误: 在配置文件中找不到 \"Nas_User_smbpasswd\": \"...\" 的配置，无法设置 Samba 密码"
    exit 1
fi

# 创建系统用户（如果不存在）
echo ">>> 配置 Samba 用户 $NAS_USER ..."
if id "$NAS_USER" &>/dev/null; then
    echo "用户 $NAS_USER 已存在，跳过 useradd"
else
    useradd -r -s /usr/sbin/nologin -m -d "/home/$NAS_USER" "$NAS_USER"
    echo "用户 $NAS_USER 已创建（禁止登录）"
fi

# 设置 Samba 密码
(echo "$SMB_PASS"; echo "$SMB_PASS") | smbpasswd -s -a "$NAS_USER"
echo "Samba 密码已设置"

# ==================== 3. 检测并开放防火墙 445 端口（局域网） ====================
get_lan_net() {
    local iface=$(ip route show default | awk '{print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
    fi
    if [ -z "$iface" ]; then
        echo "无法检测局域网接口" >&2
        return 1
    fi
    local ip_cidr=$(ip -o -4 addr show dev "$iface" | awk '{print $4}' | head -1)
    if [ -z "$ip_cidr" ]; then
        echo "无法获取接口 $iface 的 IPv4 地址" >&2
        return 1
    fi
    local net=$(echo "$ip_cidr" | sed -E 's/([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+\/[0-9]+/\1.0\/24/')
    echo "$net"
}

if command -v ufw &> /dev/null; then
    if ufw status | grep -q "Status: active"; then
        echo ">>> 检查防火墙 445 端口是否开放..."
        if ufw status | grep -q "445.*ALLOW"; then
            echo "445 端口已开放，跳过防火墙配置。"
        else
            echo "445 端口未开放，正在开放（仅限局域网）..."
            LAN_NET=$(get_lan_net)
            if [ -z "$LAN_NET" ]; then
                echo "警告: 无法自动检测局域网网段，将开放给任意来源（不推荐）"
                ufw allow 445 comment "SMB port from any"
            else
                ufw allow from "$LAN_NET" to any port 445 comment "SMB port from LAN"
                echo "已允许 $LAN_NET 访问 445 端口"
            fi
            ufw reload
        fi
    else
        echo "ufw 未启用，跳过防火墙配置（请确保网络环境安全）"
    fi
else
    echo "ufw 未安装，跳过防火墙端口开放"
fi

# ==================== 4. 生成 smb.conf（自动设置 valid users） ====================
SMB_CONF="/etc/samba/smb.conf"
BACKUP_CONF="${SMB_CONF}.bak"
TEMP_JSON=$(mktemp)
TEMP_KV=$(mktemp)

sed -n '/###SMB_CONFIG###/,/###SMB_CONFIG###/p' "$INPUT_FILE" | \
    grep -v '###SMB_CONFIG###' > "$TEMP_JSON"

if [ ! -s "$TEMP_JSON" ]; then
    echo "错误: 未找到标记段或段内为空"
    rm -f "$TEMP_JSON" "$TEMP_KV"
    exit 1
fi

# 补齐花括号
FIRST_CHAR=$(head -c1 "$TEMP_JSON")
LAST_CHAR=$(tail -c1 "$TEMP_JSON")
if [ "$FIRST_CHAR" != "{" ] && [ "$LAST_CHAR" != "}" ]; then
    { echo "{"; cat "$TEMP_JSON"; echo "}"; } > "${TEMP_JSON}.tmp"
    mv "${TEMP_JSON}.tmp" "$TEMP_JSON"
fi

# 提取共享名
SECTION_NAME=$(grep -E '"Name"[[:space:]]*:' "$TEMP_JSON" | head -1 | sed -E 's/.*"Name"[[:space:]]*:[[:space:]]*"?([^",]+)"?.*/\1/')
if [ -z "$SECTION_NAME" ]; then
    echo "错误: 无法提取 Name 字段"
    rm -f "$TEMP_JSON" "$TEMP_KV"
    exit 1
fi

# 提取其他键值对
KV_LINES=$(grep -E '"[^"]+"[[:space:]]*:[[:space:]]*' "$TEMP_JSON" | grep -v '"Name"[[:space:]]*:')
if [ -z "$KV_LINES" ]; then
    echo "错误: 未找到键值对"
    rm -f "$TEMP_JSON" "$TEMP_KV"
    exit 1
fi

# 将键值对写入临时文件
echo "$KV_LINES" | while IFS= read -r line; do
    key=$(echo "$line" | sed -E 's/^[[:space:]]*"([^"]+)"[[:space:]]*:.*$/\1/')
    value=$(echo "$line" | sed -E 's/.*:[[:space:]]*"?([^",]+)"?.*$/\1/')
    echo "$key=$value"
done > "$TEMP_KV"

# 读取到关联数组
declare -A SMB_OPTS
while IFS='=' read -r k v; do
    SMB_OPTS["$k"]="$v"
done < "$TEMP_KV"

# 确保 valid users 字段值为 NAS_USER（覆盖或新增）
SMB_OPTS["valid users"]="$NAS_USER"
echo "自动设置 valid users = $NAS_USER"

# 提取共享路径（用于后续权限设置）
SHARE_PATH="${SMB_OPTS["path"]}"
if [ -z "$SHARE_PATH" ]; then
    echo "警告: 未找到 path 字段，无法设置目录所有权"
fi

# 备份原配置
[ -f "$SMB_CONF" ] && cp "$SMB_CONF" "$BACKUP_CONF"

# 生成新配置文件
{
    echo "# Generated from $INPUT_FILE on $(date)"
    echo "# Backup: $BACKUP_CONF"
    echo ""
    echo "[$SECTION_NAME]"
    for k in "${!SMB_OPTS[@]}"; do
        echo "   $k = ${SMB_OPTS[$k]}"
    done
} > "$SMB_CONF"

rm -f "$TEMP_JSON" "$TEMP_KV"

echo "已导出至 $SMB_CONF"
cat "$SMB_CONF"

# ==================== 5. 处理目录所有权（跳过 Manage 子目录） ====================
if [ -n "$SHARE_PATH" ] && [ -d "$SHARE_PATH" ]; then
    if ! id "$NAS_USER" &>/dev/null; then
        echo "错误: 用户 $NAS_USER 不存在，无法设置目录所有权"
        exit 1
    fi

    EXCLUDE_DIR="Manage"
    echo "正在将共享目录 $SHARE_PATH 的所有权更改为 $NAS_USER（跳过 $EXCLUDE_DIR 子目录）..."
    find "$SHARE_PATH" -maxdepth 1 -name "$EXCLUDE_DIR" -prune -o -exec chown "$NAS_USER":"$NAS_USER" {} \;
    echo "已跳过 $SHARE_PATH/$EXCLUDE_DIR 目录及其内容。"

    echo "正在设置目录权限为 755（跳过 $EXCLUDE_DIR 子目录）..."
    find "$SHARE_PATH" -maxdepth 1 -name "$EXCLUDE_DIR" -prune -o -exec chmod 755 {} \;
    find "$SHARE_PATH" -path "$SHARE_PATH/$EXCLUDE_DIR" -prune -o \( -type d -exec chmod 755 {} \; -o -type f -exec chmod 644 {} \; \)
    echo "共享目录权限设置完成（$EXCLUDE_DIR 已保留原权限）。"
else
    if [ -z "$SHARE_PATH" ]; then
        echo "警告: 未获取到 path 值，跳过目录所有权更改。"
    elif [ ! -d "$SHARE_PATH" ]; then
        echo "警告: 共享目录 $SHARE_PATH 不存在，跳过所有权更改。"
    fi
fi

echo "全部操作完成。"
