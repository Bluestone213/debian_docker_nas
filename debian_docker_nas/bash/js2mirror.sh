#!/bin/bash
# ============================================================
# 交互式脚本：读取 JSON 片段配置 Debian 源、安装软件包
# 运行：sudo ./js2mirror.sh --config.json
# ============================================================

set -e

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行: sudo $0 --配置文件.json"
    exit 1
fi

# 检查 whiptail
if ! command -v whiptail &> /dev/null; then
    echo "正在安装 whiptail ..."
    apt-get update && apt-get install -y whiptail
fi

# 解析参数
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

# ========== 1. 提取 ###MIRROR### 段并解析 ==========
TEMP_CFG=$(mktemp)
sed -n '/###MIRROR###/,/###MIRROR###/p' "$INPUT_FILE" | \
    grep -v '###MIRROR###' | \
    grep -v '^\s*#' | \
    grep -v '^\s*$' > "$TEMP_CFG"

if [ ! -s "$TEMP_CFG" ]; then
    echo "错误: 未找到有效的 ###MIRROR### 配置段"
    rm -f "$TEMP_CFG"
    exit 1
fi

MIRROR=""
PACKAGES_RAW=""

while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue

    key=$(echo "$line" | sed -E 's/^[[:space:]]*["“]([^"“”]+)["“”][[:space:]]*:.*$/\1/')
    value=$(echo "$line" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/')
    
    case "$key" in
        Mirror) MIRROR="$value" ;;
        Packages_standard) PACKAGES_RAW="$value" ;;
    esac
done < "$TEMP_CFG"
rm -f "$TEMP_CFG"

if [ -z "$MIRROR" ]; then
    echo "警告: 未找到 Mirror 配置，跳过源修改"
fi
if [ -z "$PACKAGES_RAW" ]; then
    echo "错误: 未找到 Packages_standard 配置"
    exit 1
fi

# ========== 2. 解析全局（不在段内）的 Nas_Admin ==========
NAS_ADMIN=""
NAS_ADMIN_LINE=$(grep -E '["“]Nas_Admin["”][[:space:]]*:' "$INPUT_FILE" | head -1)
if [ -n "$NAS_ADMIN_LINE" ]; then
    NAS_ADMIN=$(echo "$NAS_ADMIN_LINE" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]+)["“”]?.*/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi

if [ -z "$NAS_ADMIN" ]; then
    echo "错误: 在配置文件中找不到 \"Nas_Admin\": \"...\" 的配置"
    exit 1
fi
echo ">>> 检测到管理员用户: $NAS_ADMIN"

# ========== 3. 检查用户是否存在，若存在则加入 sudo 组，若不存在则报错退出 ==========
if ! id "$NAS_ADMIN" &>/dev/null; then
    echo "错误: 用户 $NAS_ADMIN 不存在，请先运行 js2system.sh 创建管理员用户。"
    exit 1
fi
echo ">>> 用户 $NAS_ADMIN 已存在，正在将其加入 sudo 组..."
usermod -aG sudo "$NAS_ADMIN"
echo "已将 $NAS_ADMIN 添加到 sudo 组"

# ========== 4. 修改 Debian 软件源 ==========
if [ -n "$MIRROR" ]; then
    if [ -f /etc/debian_version ]; then
        DEBIAN_VER=$(cat /etc/debian_version | cut -d. -f1)
    else
        echo "无法确定 Debian 版本，跳过源修改"
        DEBIAN_VER=""
    fi

    case "$DEBIAN_VER" in
        11) CODENAME="bullseye" ;;
        12) CODENAME="bookworm" ;;
        13) CODENAME="trixie" ;;
        *) echo "不支持 Debian 版本 $DEBIAN_VER 或未检测到，跳过"; CODENAME="" ;;
    esac

    if [ -n "$CODENAME" ]; then
        case "$MIRROR" in
            tsinghua)
                MIRROR_URL="https://mirrors.tuna.tsinghua.edu.cn/debian"
                ;;
            163)
                MIRROR_URL="http://mirrors.163.com/debian"
                ;;
            aliyun)
                MIRROR_URL="http://mirrors.aliyun.com/debian"
                ;;
            tencent)
                MIRROR_URL="http://mirrors.tencent.com/debian"
                ;;
            *)
                echo "未知镜像源: $MIRROR，跳过"
                MIRROR_URL=""
                ;;
        esac

        if [ -n "$MIRROR_URL" ]; then
            echo "正在更换软件源为 $MIRROR ($CODENAME) ..."
            cat > /etc/apt/sources.list <<EOF
deb $MIRROR_URL $CODENAME main contrib non-free non-free-firmware
deb $MIRROR_URL $CODENAME-updates main contrib non-free non-free-firmware
deb $MIRROR_URL $CODENAME-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $CODENAME-security main contrib non-free non-free-firmware
EOF
            apt-get update
        fi
    fi
fi

# ========== 5. 交互式安装软件包 ==========
IFS=',' read -r -a ALL_PACKAGES <<< "$PACKAGES_RAW"
for i in "${!ALL_PACKAGES[@]}"; do
    ALL_PACKAGES[$i]=$(echo "${ALL_PACKAGES[$i]}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
done

WHIPTAIL_ARGS=()
for pkg in "${ALL_PACKAGES[@]}"; do
    WHIPTAIL_ARGS+=("$pkg" "" "ON")
done

SELECTED=$(whiptail --title "软件包安装选择" \
    --checklist \
    "请选择要安装的软件包（空格键选择/取消，方向键移动）" \
    20 60 10 \
    "${WHIPTAIL_ARGS[@]}" \
    3>&1 1>&2 2>&3)

if [ $? -ne 0 ]; then
    echo "用户取消，退出"
    exit 1
fi

SELECTED_PKGS=$(echo $SELECTED | tr -d '"')
if [ -z "$SELECTED_PKGS" ]; then
    echo "未选择任何软件包，跳过安装"
else
    echo "即将安装: $SELECTED_PKGS"
    apt-get update
    apt-get install -y $SELECTED_PKGS
fi

# ========== 6. 修改 SSH 配置，仅允许 root 和 Nas_Admin 登录 ==========
SSH_CONFIG="/etc/ssh/sshd_config"
BACKUP_SSH="${SSH_CONFIG}.backup_nasadmin"
if [ ! -f "$BACKUP_SSH" ]; then
    cp "$SSH_CONFIG" "$BACKUP_SSH"
    echo "已备份 SSH 配置到 $BACKUP_SSH"
fi

sed -i '/^AllowUsers/d' "$SSH_CONFIG"
echo "AllowUsers root $NAS_ADMIN" >> "$SSH_CONFIG"
echo "SSH 配置已修改，仅允许 root 和 $NAS_ADMIN 用户登录"

systemctl restart sshd
echo "SSH 服务已重启"

echo "所有操作完成。"
echo "提示: 系统已限制 SSH 登录用户仅为 root 和 $NAS_ADMIN，请妥善保管相关账户密码。"
