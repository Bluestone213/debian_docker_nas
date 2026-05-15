#!/bin/bash
# ============================================================
# 脚本：basic_config.sh
# 功能：执行基础配置（系统、镜像源、防火墙、Samba、网络）
# 用法：basic_config.sh --json <config.json> [--system|--mirror|--ufw|--smb|--net|--all]
# 说明：此脚本由 main.sh 调用，不独立运行，不检查 root 权限
# ============================================================

set -e

# ---------------------------- 解析参数 ----------------------------
JSON_FILE=""
TASK=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)
            JSON_FILE="$2"
            shift 2
            ;;
        --system|--mirror|--ufw|--smb|--net|--all)
            TASK="${1#--}"
            shift
            ;;
        *)
            echo "错误: 未知参数 $1"
            exit 1
            ;;
    esac
done

if [[ -z "$JSON_FILE" ]] || [[ ! -f "$JSON_FILE" ]]; then
    echo "错误: 必须指定有效的 JSON 配置文件 (--json <file>)"
    exit 1
fi

if [[ -z "$TASK" ]]; then
    TASK="all"
fi

# ---------------------------- 全局辅助函数 ----------------------------
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

parse_section() {
    local section_start="$1"
    local section_end="$2"
    sed -n "/$section_start/,/$section_end/p" "$JSON_FILE" | grep -v "$section_start" | grep -v "$section_end" | grep -v '^\s*#' | grep -v '^\s*$'
}

extract_value_from_block() {
    local block="$1"
    local key="$2"
    echo "$block" | grep -E "[\"“]${key}[\"”][[:space:]]*:" | head -1 | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/'
}

# ---------------------------- 加载所有配置 ----------------------------
declare -A CFG

load_config() {
    local host_block=$(parse_section "###HOST###" "###HOST###")
    CFG["Nas_Hostname"]=$(extract_value_from_block "$host_block" "Nas_Hostname")

    local user_block=$(parse_section "###USER###" "###USER###")
    CFG["Nas_Admin"]=$(extract_value_from_block "$user_block" "Nas_Admin")
    CFG["Nas_Admin_passwd"]=$(extract_value_from_block "$user_block" "Nas_Admin_passwd")
    CFG["Nas_Root_passwd"]=$(extract_value_from_block "$user_block" "Nas_Root_passwd")

    local mirror_block=$(parse_section "###MIRROR###" "###MIRROR###")
    CFG["Mirror"]=$(extract_value_from_block "$mirror_block" "Mirror")
    CFG["Packages_standard"]=$(extract_value_from_block "$mirror_block" "Packages_standard")

    local port_block=$(parse_section "###PORT###" "###PORT###")
    CFG["SSH_0"]=$(extract_value_from_block "$port_block" "SSH_0")
    CFG["SSH_1"]=$(extract_value_from_block "$port_block" "SSH_1")
    CFG["SSH_2"]=$(extract_value_from_block "$port_block" "SSH_2")
    CFG["SMB"]=$(extract_value_from_block "$port_block" "SMB")
    CFG["PORT_BLOCK"]="$port_block"

    local smb_user_block=$(parse_section "###SMB_USER###" "###SMB_USER###")
    if [[ -n "$smb_user_block" ]]; then
        CFG["Nas_User"]=$(extract_value_from_block "$smb_user_block" "Nas_User")
        CFG["Nas_User_smbpasswd"]=$(extract_value_from_block "$smb_user_block" "Nas_User_smbpasswd")
    else
        local global_user=$(grep -E '["“]Nas_User["”][[:space:]]*:' "$JSON_FILE" | head -1)
        CFG["Nas_User"]=$(echo "$global_user" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]+)["“”]?.*/\1/')
        local global_pass=$(grep -E '["“]Nas_User_smbpasswd["”][[:space:]]*:' "$JSON_FILE" | head -1)
        CFG["Nas_User_smbpasswd"]=$(echo "$global_pass" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]+)["“”]?.*/\1/')
    fi

    CFG["SMB_CONFIG_BLOCK"]=$(parse_section "###SMB_CONFIG###" "###SMB_CONFIG###")

    local net_block=$(parse_section "###NETWORK###" "###NETWORK###")
    CFG["address"]=$(extract_value_from_block "$net_block" "address")
    CFG["netmask"]=$(extract_value_from_block "$net_block" "netmask")
    CFG["gateway"]=$(extract_value_from_block "$net_block" "gateway")
    CFG["dns-nameservers"]=$(extract_value_from_block "$net_block" "dns-nameservers")
}

# ---------------------------- 系统配置 ----------------------------
do_system() {
    echo ">>> 执行系统配置 (主机名、用户管理) <<<"

    local hostname="${CFG["Nas_Hostname"]}"
    if [[ -n "$hostname" ]]; then
        local current=$(hostname)
        if [[ "$current" != "$hostname" ]]; then
            echo "$hostname" > /etc/hostname
            if grep -q "127.0.1.1" /etc/hosts; then
                sed -i "s/127.0.1.1\s.*/127.0.1.1\t$hostname/" /etc/hosts
            else
                echo "127.0.1.1\t$hostname" >> /etc/hosts
            fi
            hostname "$hostname"
            echo "主机名已修改为 $hostname"
        fi
    fi

    local admin="${CFG["Nas_Admin"]}"
    local existing=$(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd | grep -v "^nobody$" | grep -v "^$admin$" | sort)
    if [[ -n "$existing" ]]; then
        echo "发现以下非 root 用户："
        echo "$existing"
        read -p "是否删除以上所有用户及其家目录？(y/n): " confirm
        if [[ "$confirm" =~ ^[Yy]$ ]]; then
            for user in $existing; do
                userdel -r "$user" 2>/dev/null || userdel "$user" 2>/dev/null || echo "无法删除 $user"
            done
            echo "用户删除完成"
        else
            echo "跳过删除"
        fi
    fi

    local admin_pass="${CFG["Nas_Admin_passwd"]}"
    local root_pass="${CFG["Nas_Root_passwd"]}"
    if [[ -z "$admin" ]] || [[ -z "$admin_pass" ]] || [[ -z "$root_pass" ]]; then
        echo "错误: 缺少管理员或密码配置"
        exit 1
    fi

    if ! id "$admin" &>/dev/null; then
        adduser --disabled-password --gecos "" "$admin"
        echo "用户 $admin 已创建"
    else
        echo "用户 $admin 已存在"
    fi
    echo "$admin:$admin_pass" | chpasswd
    echo "root:$root_pass" | chpasswd
    echo "用户密码已设置"

    echo "系统与用户信息配置完成"
}

# ---------------------------- 镜像源与软件 ----------------------------
do_mirror() {
    echo ">>> 执行镜像源配置与软件安装 <<<"

    if ! command -v whiptail &> /dev/null; then
        echo "正在安装 whiptail ..."
        apt-get update && apt-get install -y whiptail
    fi

    local mirror="${CFG["Mirror"]}"
    local packages="${CFG["Packages_standard"]}"
    local admin="${CFG["Nas_Admin"]}"

    if [[ -n "$mirror" ]] && [[ -f /etc/debian_version ]]; then
        local debian_ver=$(cat /etc/debian_version | cut -d. -f1)
        local codename=""
        case "$debian_ver" in
            11) codename="bullseye" ;;
            12) codename="bookworm" ;;
            13) codename="trixie" ;;
            *) echo "不支持的 Debian 版本 $debian_ver，跳过源修改"
        esac
        if [[ -n "$codename" ]]; then
            local mirror_url=""
            case "$mirror" in
                tsinghua) mirror_url="https://mirrors.tuna.tsinghua.edu.cn/debian" ;;
                163) mirror_url="http://mirrors.163.com/debian" ;;
                aliyun) mirror_url="http://mirrors.aliyun.com/debian" ;;
                tencent) mirror_url="http://mirrors.tencent.com/debian" ;;
                *) echo "未知镜像源: $mirror，跳过"
            esac
            if [[ -n "$mirror_url" ]]; then
                cat > /etc/apt/sources.list <<EOF
deb $mirror_url $codename main contrib non-free non-free-firmware
deb $mirror_url $codename-updates main contrib non-free non-free-firmware
deb $mirror_url $codename-backports main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $codename-security main contrib non-free non-free-firmware
EOF
                apt-get update
                echo "软件源已更换为 $mirror"
            fi
        fi
    fi

    if [[ -n "$packages" ]]; then
        IFS=',' read -ra pkg_list <<< "$packages"
        local whiptail_args=()
        for pkg in "${pkg_list[@]}"; do
            pkg=$(echo "$pkg" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            whiptail_args+=("$pkg" "" "ON")
        done
        local selected
        selected=$(whiptail --title "软件包安装选择" \
            --checklist "请选择要安装的软件包（空格键选择/取消）" \
            20 60 10 "${whiptail_args[@]}" 3>&1 1>&2 2>&3)
        if [[ $? -eq 0 ]] && [[ -n "$selected" ]]; then
            selected=$(echo "$selected" | tr -d '"')
            apt-get update
            apt-get install -y $selected
            echo "已安装: $selected"
        else
            echo "用户取消或未选择软件包"
        fi
    fi

    local sudo_installed=false
    local user_exists=false
    if command -v sudo &> /dev/null; then
        sudo_installed=true
        if id "$admin" &>/dev/null; then
            user_exists=true
            usermod -aG sudo "$admin"
            echo "$admin 已加入 sudo 组"
        else
            echo "警告: 用户 $admin 不存在，无法添加到 sudo 组"
        fi
    fi

    local ssh_installed=false
    local ssh0="${CFG["SSH_0"]}"
    local ssh1="${CFG["SSH_1"]}"
    local ssh2="${CFG["SSH_2"]}"
    if command -v sshd &>/dev/null || dpkg -l openssh-server 2>/dev/null | grep -q "^ii"; then
        ssh_installed=true
        local ssh_config="/etc/ssh/sshd_config"
        local backup_ssh="${ssh_config}.backup_nasadmin"
        if [[ ! -f "$backup_ssh" ]]; then
            cp "$ssh_config" "$backup_ssh"
            echo "已备份 SSH 配置到 $backup_ssh"
        fi
        sed -i '/^AllowUsers/d' "$ssh_config"
        echo "AllowUsers root $admin" >> "$ssh_config"
        local added_ports=()
        for port in "$ssh1" "$ssh2"; do
            if [[ -n "$port" ]] && ! grep -qE "^Port $port\$" "$ssh_config"; then
                echo "Port $port" >> "$ssh_config"
                added_ports+=("$port")
            fi
        done
        if [[ ${#added_ports[@]} -gt 0 ]]; then
            echo "已添加额外 SSH 端口: ${added_ports[*]}"
        else
            echo "无新增 SSH 端口（可能已存在）"
        fi
        systemctl restart sshd
        echo "SSH 已限制仅 root 和 $admin 可登录"
    fi

    echo "镜像源与软件配置完成"
    if [[ "$sudo_installed" == true ]] && [[ "$user_exists" == false ]]; then
        echo "提示: 用户 $admin 不存在，无法添加到 sudo 组。请先执行「系统与用户信息」创建用户。"
    fi
    if [[ "$ssh_installed" == true ]] && [[ "$ssh0" == "22" ]]; then
        echo "警告: 开放了 SSH 端口 22（默认端口），建议修改为其他端口以提高安全性。"
    fi
}

# ---------------------------- 防火墙配置 ----------------------------
do_ufw() {
    echo ">>> 执行防火墙端口配置 <<<"

    local lan_net=$(get_lan_net)
    if [[ -z "$lan_net" ]]; then
        echo "错误: 无法自动检测局域网网段"
        exit 1
    fi
    echo "局域网网段: $lan_net"

    if ufw status | grep -q "Status: inactive"; then
        ufw --force enable
    fi

    local opened_ports=()

    add_ufw_rule() {
        local port_spec="$1"
        local source_type="$2"
        local comment="$3"

        if [[ "$port_spec" =~ ^([0-9]+)/(tcp|udp)$ ]]; then
            local port="${BASH_REMATCH[1]}"
            local proto="${BASH_REMATCH[2]}"
            if [[ "$source_type" == "LAN" ]]; then
                ufw allow from "$lan_net" to any port "$port" proto "$proto" comment "$comment"
                echo "  + $port/$proto 允许来自 $lan_net"
                opened_ports+=("$port/$proto (LAN)")
            else
                ufw allow proto "$proto" to any port "$port" comment "$comment"
                echo "  + $port/$proto 允许来自任意来源"
                opened_ports+=("$port/$proto (ANY)")
            fi
        elif [[ "$port_spec" =~ ^([0-9]+)-any$ ]]; then
            local port="${BASH_REMATCH[1]}"
            ufw allow to any port "$port" comment "$comment"
            echo "  + $port (tcp+udp) 允许来自任意来源"
            opened_ports+=("$port (tcp+udp, ANY)")
        elif [[ "$port_spec" =~ ^[0-9]+$ ]]; then
            local port="$port_spec"
            if [[ "$source_type" == "LAN" ]]; then
                ufw allow from "$lan_net" to any port "$port" comment "$comment"
                echo "  + $port (tcp+udp) 允许来自 $lan_net"
                opened_ports+=("$port (tcp+udp, LAN)")
            else
                ufw allow to any port "$port" comment "$comment"
                echo "  + $port (tcp+udp) 允许来自任意来源"
                opened_ports+=("$port (tcp+udp, ANY)")
            fi
        else
            echo "  警告: 无法识别的端口规格 '$port_spec'，跳过"
        fi
    }

    local port_block="${CFG["PORT_BLOCK"]}"
    if [[ -z "$port_block" ]]; then
        echo "错误: 未找到 ###PORT### 配置段"
        exit 1
    fi

    while IFS= read -r line; do
        key=$(echo "$line" | sed -E 's/^[[:space:]]*["“]([^"“”]+)["“”][[:space:]]*:.*$/\1/')
        value=$(echo "$line" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/')
        if [[ -n "$key" ]] && [[ -n "$value" ]]; then
            if [[ "$value" =~ ^[0-9] ]] || [[ "$value" =~ ^[0-9]+/(tcp|udp) ]] || [[ "$value" =~ ^[0-9]+-any$ ]]; then
                if [[ "$value" =~ -any$ ]]; then
                    add_ufw_rule "$value" "ANY" "$key port from any"
                else
                    add_ufw_rule "$value" "LAN" "$key port from LAN"
                fi
            fi
        fi
    done <<< "$port_block"

    ufw reload
    echo "已开放以下端口："
    for p in "${opened_ports[@]}"; do
        echo "  - $p"
    done
    echo "防火墙基础配置完成"
}

# ---------------------------- Samba 共享配置（修复格式） ----------------------------
do_smb() {
    echo ">>> 执行 Samba 共享配置 <<<"

    if ! command -v smbd &>/dev/null && ! dpkg -l samba 2>/dev/null | grep -q "^ii"; then
        echo "Samba 未安装，跳过共享配置。"
        return 0
    fi

    local nas_user="${CFG["Nas_User"]}"
    local smb_pass="${CFG["Nas_User_smbpasswd"]}"
    if [[ -z "$nas_user" ]] || [[ -z "$smb_pass" ]]; then
        echo "错误: 缺少 SMB 用户或密码配置"
        exit 1
    fi

    if ! id "$nas_user" &>/dev/null; then
        useradd -r -s /usr/sbin/nologin -m -d "/home/$nas_user" "$nas_user"
        echo "用户 $nas_user 已创建"
    fi
    (echo "$smb_pass"; echo "$smb_pass") | smbpasswd -s -a "$nas_user"
    echo "Samba 密码已设置"

    local smb_config_block="${CFG["SMB_CONFIG_BLOCK"]}"
    if [[ -z "$smb_config_block" ]]; then
        echo "错误: 未找到 ###SMB_CONFIG### 配置段"
        exit 1
    fi

    local share_name=$(extract_value_from_block "$smb_config_block" "Name")
    local share_path=$(extract_value_from_block "$smb_config_block" "path")
    if [[ -z "$share_name" ]] || [[ -z "$share_path" ]]; then
        echo "错误: 共享名或路径缺失"
        exit 1
    fi

    local smb_conf="/etc/samba/smb.conf"
    if [[ -f "$smb_conf" ]]; then
        cp "$smb_conf" "${smb_conf}.bak"
        echo "已备份原配置到 ${smb_conf}.bak"
    fi

    # 生成正确的 smb.conf 格式：去除引号和逗号
    {
        echo "# Generated from $JSON_FILE on $(date)"
        echo "[$share_name]"
        echo "$smb_config_block" | while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            # 去除行首尾空格
            line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            # 提取键名（去掉中文或英文双引号）
            key=$(echo "$line" | sed -E 's/^["“]([^"“”]+)["“”][[:space:]]*:.*$/\1/')
            # 提取值（去掉引号、尾部逗号）
            value=$(echo "$line" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]*?)["“”]?[[:space:]]*,?[[:space:]]*$/\1/')
            if [[ -n "$key" && -n "$value" ]]; then
                echo "   $key = $value"
            fi
        done
        echo "   valid users = $nas_user"
    } > "$smb_conf"

    echo "Samba 配置文件已生成，内容如下："
    cat "$smb_conf"

    if [[ -d "$share_path" ]]; then
        local exclude_dir="Manage"
        find "$share_path" -maxdepth 1 -name "$exclude_dir" -prune -o -exec chown "$nas_user:$nas_user" {} \;
        find "$share_path" -maxdepth 1 -name "$exclude_dir" -prune -o -exec chmod 755 {} \;
        find "$share_path" -path "$share_path/$exclude_dir" -prune -o \( -type d -exec chmod 755 {} \; -o -type f -exec chmod 644 {} \; \)
        echo "目录权限已设置（跳过 $exclude_dir）"
    else
        echo "警告: 共享目录 $share_path 不存在，跳过权限设置"
    fi

    systemctl restart smbd 2>/dev/null && echo "Samba 服务已重启" || echo "Samba 服务未运行，请手动启动"

    if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
        if ! ufw status | grep -q "445.*ALLOW"; then
            echo "警告: 防火墙 445 端口未开放，Samba 服务可能无法被访问。请稍后使用「防火墙基础配置」开放端口。"
        fi
    fi
    echo "开放SMB共享配置完成"
}

# ---------------------------- 网络配置（固定IP） ----------------------------
do_net() {
    echo ">>> 执行网络静态 IP 配置 <<<"

    local address="${CFG["address"]}"
    local netmask="${CFG["netmask"]}"
    local gateway="${CFG["gateway"]}"
    local dns="${CFG["dns-nameservers"]}"

    if [[ -z "$address" ]] || [[ -z "$netmask" ]] || [[ -z "$gateway" ]]; then
        echo "错误: 网络配置不完整 (address/netmask/gateway)"
        exit 1
    fi

    local iface=$(ip route show default | awk '{print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        iface=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
    fi
    if [[ -z "$iface" ]]; then
        echo "错误: 无法检测网络接口"
        exit 1
    fi
    echo "活动接口: $iface"

    local interfaces="/etc/network/interfaces"
    local backup_suffix=".bak_$(date +%Y%m%d_%H%M%S)"
    cp "$interfaces" "${interfaces}${backup_suffix}"
    echo "已备份原网络配置到 ${interfaces}${backup_suffix}"

    sed -i "/^[[:space:]]*auto $iface\$/,/^$/d" "$interfaces"
    sed -i "/^[[:space:]]*allow-hotplug $iface\$/,/^$/d" "$interfaces"
    sed -i "/^[[:space:]]*iface $iface /,/^$/d" "$interfaces"

    cat >> "$interfaces" <<EOF

# Static IP configured by basic_config.sh on $(date)
auto $iface
iface $iface inet static
    address $address
    netmask $netmask
    gateway $gateway
EOF
    if [[ -n "$dns" ]]; then
        IFS=',' read -ra dns_list <<< "$dns"
        for ns in "${dns_list[@]}"; do
            ns=$(echo "$ns" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            echo "    dns-nameservers $ns" >> "$interfaces"
        done
    fi
    echo "网络配置文件已更新"

    local resolv="/etc/resolv.conf"
    local resolv_target="$resolv"
    if [[ -L "$resolv" ]]; then
        resolv_target=$(readlink -f "$resolv")
    fi
    cp "$resolv_target" "${resolv_target}${backup_suffix}" 2>/dev/null || true
    {
        echo "# Generated by basic_config.sh on $(date)"
        if [[ -n "$dns" ]]; then
            IFS=',' read -ra dns_list <<< "$dns"
            for ns in "${dns_list[@]}"; do
                ns=$(echo "$ns" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                echo "nameserver $ns"
            done
        fi
        echo "# 114DNS (China)"
        echo "nameserver 114.114.114.114"
        echo "# DNSPod (China)"
        echo "nameserver 119.29.29.29"
        echo "# AliDNS (China)"
        echo "nameserver 223.5.5.5"
    } > "$resolv_target"
    echo "DNS 已配置"

    echo "当前 DNS 配置："
    grep -E '^nameserver' "$resolv_target" | while read -r line; do
        echo "  $line"
    done

    echo ""
    echo "网络配置已写入："
    echo "  接口: $iface"
    echo "  IP 地址: $address"
    echo "  子网掩码: $netmask"
    echo "  网关: $gateway"
    echo "  DNS: $(grep nameserver "$resolv_target" | awk '{print $2}' | tr '\n' ' ')"
    echo ""
    echo "注意: 静态 IP 配置尚未生效，请择机手动重启网络或重启系统。"
    echo "网络配置（固定IP）完成"
}

# ---------------------------- 主控逻辑 ----------------------------
load_config

case "$TASK" in
    system)
        do_system
        ;;
    mirror)
        do_mirror
        ;;
    ufw)
        do_ufw
        ;;
    smb)
        do_smb
        ;;
    net)
        do_net
        ;;
    all)
        do_system
        do_mirror
        do_ufw
        do_smb
        do_net
        echo "一键配置完成"
        ;;
    *)
        echo "错误: 未知任务 '$TASK'"
        exit 1
        ;;
esac
