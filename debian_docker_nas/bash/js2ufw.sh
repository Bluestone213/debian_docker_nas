#!/bin/bash
# ============================================================
# 脚本功能：从配置段读取端口，配置 SSH 并开放防火墙规则
# 用法：sudo ./js2port.sh --config.json
# ============================================================

set -e

# ----------------------------- 帮助 -----------------------------
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat << EOF
用法: sudo $0 --配置文件.json

从配置文件的 ###PORT### 段中读取端口定义，自动完成：
  1. 检测局域网网段（/24）
  2. 若 SSH 已安装，添加 SSH_1、SSH_2 到 sshd_config，并开放三个 SSH 端口给局域网
  3. 若 Samba 已安装，开放 SMB 端口给局域网
  4. 其他端口按规格开放（支持 /tcp、/udp、-any 等）
  5. 配置 ufw 并启用

注意：如果开放了 445 端口，会提示稍后使用 js2smb.sh 配置 Samba。

示例: sudo $0 --myports.json
EOF
    exit 0
fi

# ----------------------------- 参数检查 -----------------------------
if [ $# -ne 1 ] || [[ ! "$1" =~ ^-- ]]; then
    echo "错误: 必须指定配置文件 (--文件名.json)"
    echo "用法: $0 --config.json"
    exit 1
fi
CONFIG_FILE="${1#--}"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "错误: 找不到文件 $CONFIG_FILE"
    exit 1
fi

# ----------------------------- 权限检查 -----------------------------
if [ "$EUID" -ne 0 ]; then
    echo "请以 root 权限运行: sudo $0 --$CONFIG_FILE"
    exit 1
fi

# ----------------------------- 依赖检查 -----------------------------
if ! command -v ufw &> /dev/null; then
    echo "错误: ufw 未安装，请先运行 apt install ufw"
    exit 1
fi

# ----------------------------- 辅助函数 -----------------------------
# 获取局域网 IPv4 网段（/24）
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

# 解析配置段，返回关联数组（通过全局变量 PORT_CONFIG）
parse_port_section() {
    local file="$1"
    local temp=$(mktemp)
    sed -n '/###PORT###/,/###PORT###/p' "$file" | \
        grep -v '###PORT###' | \
        grep -v '^\s*#' | \
        grep -v '^\s*$' > "$temp"
    if [ ! -s "$temp" ]; then
        echo "错误: 未找到有效的 ###PORT### 配置段" >&2
        rm -f "$temp"
        return 1
    fi
    while IFS= read -r line; do
        local key=$(echo "$line" | sed -E 's/^[[:space:]]*["“]([^"“”]+)["“”][[:space:]]*:.*$/\1/')
        local value=$(echo "$line" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/')
        if [ -n "$key" ]; then
            eval "PORT_CONFIG[\"$key\"]=\"$value\""
        fi
    done < "$temp"
    rm -f "$temp"
    return 0
}

# 添加 ufw 规则（增加 445 端口提示）
add_ufw_rule() {
    local port_spec="$1"
    local source_type="$2"
    local comment="$3"

    if [[ "$port_spec" =~ ^([0-9]+)/(tcp|udp)$ ]]; then
        local port="${BASH_REMATCH[1]}"
        local proto="${BASH_REMATCH[2]}"
        if [ "$source_type" = "LAN" ]; then
            ufw allow from "$LAN_NET" to any port "$port" proto "$proto" comment "$comment"
            echo "  + $port/$proto 允许来自 $LAN_NET"
        else
            ufw allow proto "$proto" to any port "$port" comment "$comment"
            echo "  + $port/$proto 允许来自任意来源"
        fi
        # 检测 445 端口
        if [ "$port" = "445" ]; then
            echo "  → 注意：已开放 445 端口（SMB），请稍后使用 js2smb.sh 配置 Samba 服务。"
        fi
    elif [[ "$port_spec" =~ ^([0-9]+)/(tcp|udp)-any$ ]]; then
        local port="${BASH_REMATCH[1]}"
        local proto="${BASH_REMATCH[2]}"
        ufw allow proto "$proto" to any port "$port" comment "$comment"
        echo "  + $port/$proto 允许来自任意来源"
        if [ "$port" = "445" ]; then
            echo "  → 注意：已开放 445 端口（SMB），请稍后使用 js2smb.sh 配置 Samba 服务。"
        fi
    elif [[ "$port_spec" =~ ^([0-9]+)-any$ ]]; then
        local port="${BASH_REMATCH[1]}"
        ufw allow to any port "$port" comment "$comment"
        echo "  + $port (tcp+udp) 允许来自任意来源"
        if [ "$port" = "445" ]; then
            echo "  → 注意：已开放 445 端口（SMB），请稍后使用 js2smb.sh 配置 Samba 服务。"
        fi
    elif [[ "$port_spec" =~ ^[0-9]+$ ]]; then
        local port="$port_spec"
        if [ "$source_type" = "LAN" ]; then
            ufw allow from "$LAN_NET" to any port "$port" comment "$comment"
            echo "  + $port (tcp+udp) 允许来自 $LAN_NET"
        else
            ufw allow to any port "$port" comment "$comment"
            echo "  + $port (tcp+udp) 允许来自任意来源"
        fi
        if [ "$port" = "445" ]; then
            echo "  → 注意：已开放 445 端口（SMB），请稍后使用 js2smb.sh 配置 Samba 服务。"
        fi
    else
        echo "  警告: 无法识别的端口规格 '$port_spec'，跳过"
    fi
}

# ----------------------------- 主流程 -----------------------------
echo ">>> 开始配置防火墙与 SSH 端口 <<<"

LAN_NET=$(get_lan_net)
if [ -z "$LAN_NET" ]; then
    echo "错误: 无法自动检测局域网网段，请检查网络配置"
    exit 1
fi
echo "局域网网段: $LAN_NET"

if ufw status | grep -q "Status: inactive"; then
    echo "ufw 当前未启用，正在启用..."
    ufw --force enable
fi
echo "ufw 已激活"

declare -A PORT_CONFIG
if ! parse_port_section "$CONFIG_FILE"; then
    exit 1
fi

# 处理 SSH 端口
SSH_INSTALLED=false
if command -v sshd &> /dev/null || dpkg -l openssh-server 2>/dev/null | grep -q "^ii"; then
    SSH_INSTALLED=true
fi

if [ "$SSH_INSTALLED" = true ]; then
    SSH0="${PORT_CONFIG["SSH_0"]}"
    SSH1="${PORT_CONFIG["SSH_1"]}"
    SSH2="${PORT_CONFIG["SSH_2"]}"
    if [ -n "$SSH0" ] && [ -n "$SSH1" ] && [ -n "$SSH2" ]; then
        echo "检测到 SSH 已安装，正在配置额外端口..."
        SSH_CONFIG="/etc/ssh/sshd_config"
        if [ ! -f "${SSH_CONFIG}.backup_by_script" ]; then
            cp "$SSH_CONFIG" "${SSH_CONFIG}.backup_by_script"
            echo "已备份 $SSH_CONFIG"
        fi
        for port in "$SSH1" "$SSH2"; do
            if ! grep -qE "^Port $port\$" "$SSH_CONFIG"; then
                echo "Port $port" >> "$SSH_CONFIG"
                echo "  + 添加 SSH 端口 $port 到配置文件"
            else
                echo "  - SSH 端口 $port 已存在，跳过"
            fi
        done
        systemctl restart sshd
        echo "SSH 服务已重启"
        for port in "$SSH0" "$SSH1" "$SSH2"; do
            add_ufw_rule "$port" "LAN" "SSH port $port from LAN"
        done
    else
        echo "警告: 配置中缺少 SSH_0/SSH_1/SSH_2 之一，跳过 SSH 端口处理"
    fi
else
    echo "SSH 未安装，跳过 SSH 端口配置"
fi

# 处理 SMB 端口（仅开放，不作配置）
SMB_INSTALLED=false
if command -v smbd &> /dev/null || dpkg -l samba 2>/dev/null | grep -q "^ii"; then
    SMB_INSTALLED=true
fi

if [ "$SMB_INSTALLED" = true ]; then
    SMB_PORT="${PORT_CONFIG["SMB"]}"
    if [ -n "$SMB_PORT" ]; then
        echo "检测到 Samba 已安装，正在开放 SMB 端口..."
        add_ufw_rule "$SMB_PORT" "LAN" "SMB port from LAN"
    else
        echo "配置中未找到 SMB 端口，跳过"
    fi
else
    echo "Samba 未安装，跳过 SMB 端口开放"
fi

# 处理其他端口
EXCLUDED_KEYS=("SSH_0" "SSH_1" "SSH_2" "SMB")
for key in "${!PORT_CONFIG[@]}"; do
    skip=0
    for ex in "${EXCLUDED_KEYS[@]}"; do
        if [ "$key" = "$ex" ]; then
            skip=1
            break
        fi
    done
    [ $skip -eq 1 ] && continue

    port_spec="${PORT_CONFIG[$key]}"
    echo "处理其他端口: $key = $port_spec"
    if [[ "$port_spec" =~ -any$ ]]; then
        add_ufw_rule "$port_spec" "ANY" "$key port from any"
    else
        add_ufw_rule "$port_spec" "LAN" "$key port from LAN"
    fi
done

echo ""
echo "========== ufw 规则汇总 =========="
ufw status numbered
echo "=================================="
echo "所有端口开放操作完成。"
