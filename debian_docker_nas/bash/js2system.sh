#!/bin/bash
# ============================================================
# 脚本功能：
#   1. 根据 ###HOST### 段设置主机名 (/etc/hostname, /etc/hosts)
#   2. 列出并询问是否删除系统中已有的非 root 用户 (UID>=1000)
#   3. 根据 ###USER### 段创建管理员用户并设置密码，修改 root 密码
# 用法：./js2user.sh --config.json
# 注意：需要在 root 环境下运行（此脚本不主动检查，由调用方保证）
# ============================================================

set -e

# 帮助信息
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat << EOF
用法: $0 --配置文件.json

从配置文件的以下段中读取配置：
  ###HOST###   -> 读取 Nas_Hostname 并设置主机名
  ###USER###   -> 读取 Nas_Admin, Nas_Admin_passwd, Nas_Root_passwd

脚本执行顺序：
  1. 修改主机名（/etc/hostname 和 /etc/hosts）
  2. 列出系统中已存在的普通用户（UID>=1000），询问是否全部删除
  3. 创建 Nas_Admin 用户（如果不存在），并设置密码
  4. 修改 root 用户密码

示例: $0 --config.json
EOF
    exit 0
fi

# 解析参数
if [[ $# -ne 1 || ! "$1" =~ ^-- ]]; then
    echo "错误: 必须指定配置文件 (--文件名.json)"
    echo "用法: $0 --config.json"
    exit 1
fi
INPUT_FILE="${1#--}"
if [ ! -f "$INPUT_FILE" ]; then
    echo "错误: 找不到文件 $INPUT_FILE"
    exit 1
fi

# ==================== 1. 处理 ###HOST### 段，设置主机名 ====================
echo ">>> 处理主机名配置 (###HOST###) ..."
TEMP_HOST=$(mktemp)
sed -n '/###HOST###/,/###HOST###/p' "$INPUT_FILE" | \
    grep -v '###HOST###' | \
    grep -v '^\s*#' | \
    grep -v '^\s*$' > "$TEMP_HOST"

if [ -s "$TEMP_HOST" ]; then
    # 解析 Nas_Hostname
    HOSTNAME_KEY="Nas_Hostname"
    HOSTNAME_VALUE=""
    while IFS= read -r line; do
        # 提取键名（支持中文双引号）
        key=$(echo "$line" | sed -E 's/^[[:space:]]*["“]([^"“”]+)["“”][[:space:]]*:.*$/\1/')
        # 提取值
        value=$(echo "$line" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/')
        if [ "$key" = "$HOSTNAME_KEY" ] && [ -n "$value" ]; then
            HOSTNAME_VALUE="$value"
        fi
    done < "$TEMP_HOST"
    rm -f "$TEMP_HOST"

    if [ -n "$HOSTNAME_VALUE" ]; then
        CURRENT_HOSTNAME=$(hostname)
        if [ "$CURRENT_HOSTNAME" != "$HOSTNAME_VALUE" ]; then
            echo "检测到新的主机名: $HOSTNAME_VALUE (当前: $CURRENT_HOSTNAME)"
            # 修改 /etc/hostname
            echo "$HOSTNAME_VALUE" > /etc/hostname
            # 修改 /etc/hosts：将旧主机名替换为新主机名（如果存在 127.0.1.1 条目）
            if grep -q "127.0.1.1" /etc/hosts; then
                sed -i "s/127.0.1.1\s.*/127.0.1.1\t$HOSTNAME_VALUE/" /etc/hosts
            else
                echo "127.0.1.1\t$HOSTNAME_VALUE" >> /etc/hosts
            fi
            # 立即生效（不重启）
            hostname "$HOSTNAME_VALUE"
            echo "主机名已修改为 $HOSTNAME_VALUE"
        else
            echo "主机名已是 $HOSTNAME_VALUE，无需修改"
        fi
    else
        echo "警告: ###HOST### 段中未找到有效的 Nas_Hostname，跳过主机名设置"
    fi
else
    echo "警告: 未找到 ###HOST### 段或该段为空，跳过主机名设置"
    rm -f "$TEMP_HOST"
fi

# ==================== 2. 静默检查系统中是否存在非 root 用户 ====================
echo ">>> 检查系统中已有的普通用户 (UID>=1000) ..."
# 获取 UID 在 1000~65533 之间的用户名（排除 nobody, 排除当前要创建的 Nas_Admin 尚未存在，但以防万一）
EXISTING_USERS=$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | grep -v "^nobody$" | sort)
if [ -n "$EXISTING_USERS" ]; then
    echo "发现以下非 root 用户："
    echo "$EXISTING_USERS" | while read -r u; do echo "  - $u"; done
    read -p "是否删除以上所有用户及其家目录？(y/n): " confirm_delete
    if [[ "$confirm_delete" =~ ^[Yy]$ ]]; then
        echo "开始删除用户..."
        for user in $EXISTING_USERS; do
            # 再次确认用户存在且不是 root 等关键用户
            if id "$user" &>/dev/null; then
                echo "正在删除用户 $user 及其家目录..."
                userdel -r "$user" 2>/dev/null || {
                    echo "警告: 删除用户 $user 失败（可能家目录不存在或无权限）"
                    userdel "$user" 2>/dev/null || echo "警告: 无法删除用户 $user"
                }
            fi
        done
        echo "用户删除操作完成。"
    else
        echo "跳过删除用户步骤。"
    fi
else
    echo "系统中没有额外的非 root 用户，无需操作。"
fi

# ==================== 3. 处理 ###USER### 段，创建管理员用户并修改密码 ====================
echo ">>> 处理用户配置 (###USER###) ..."
TEMP_CFG=$(mktemp)
sed -n '/###USER###/,/###USER###/p' "$INPUT_FILE" | \
    grep -v '###USER###' | \
    grep -v '^\s*#' | \
    grep -v '^\s*$' > "$TEMP_CFG"

if [ ! -s "$TEMP_CFG" ]; then
    echo "错误: 未找到有效的 ###USER### 配置段"
    rm -f "$TEMP_CFG"
    exit 1
fi

# 解析键值对（支持中文双引号）
declare -A CONFIG
while IFS= read -r line; do
    # 提取键名
    key=$(echo "$line" | sed -E 's/^[[:space:]]*["“]([^"“”]+)["“”][[:space:]]*:.*$/\1/')
    # 提取值（去除引号和尾部逗号）
    value=$(echo "$line" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/')
    if [ -n "$key" ]; then
        CONFIG["$key"]="$value"
    fi
done < "$TEMP_CFG"
rm -f "$TEMP_CFG"

# 获取配置项
NAS_ADMIN="${CONFIG["Nas_Admin"]}"
NAS_ADMIN_PASS="${CONFIG["Nas_Admin_passwd"]}"
ROOT_PASS="${CONFIG["Nas_Root_passwd"]}"

# 检查必要项
if [ -z "$NAS_ADMIN" ]; then
    echo "错误: 配置中缺少 Nas_Admin 用户名"
    exit 1
fi
if [ -z "$NAS_ADMIN_PASS" ]; then
    echo "错误: 配置中缺少 Nas_Admin_passwd 密码"
    exit 1
fi
if [ -z "$ROOT_PASS" ]; then
    echo "错误: 配置中缺少 Nas_Root_passwd 密码"
    exit 1
fi

echo ">>> 检测到管理员用户: $NAS_ADMIN"

# 创建 Nas_Admin 用户并设置密码
if id "$NAS_ADMIN" &>/dev/null; then
    echo "用户 $NAS_ADMIN 已存在，跳过创建"
else
    echo "正在创建用户 $NAS_ADMIN ..."
    adduser --disabled-password --gecos "" "$NAS_ADMIN"
    echo "用户 $NAS_ADMIN 已创建"
fi

# 设置用户密码
echo "设置用户 $NAS_ADMIN 的密码..."
echo "$NAS_ADMIN:$NAS_ADMIN_PASS" | chpasswd
echo "用户 $NAS_ADMIN 密码已设置"

# 修改 root 密码
echo "正在修改 root 用户密码..."
echo "root:$ROOT_PASS" | chpasswd
echo "root 密码已更改"

echo "用户配置操作完成。"
