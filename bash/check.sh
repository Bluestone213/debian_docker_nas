#!/bin/bash
# 退出前检查：优先处理 docker 相关，后处理 ssh、网络、清理临时目录

echo "===== 执行退出前检查 ====="

# 1. 检查 docker-compose.yml 文件并复制到 dockerdb_dir/bash 目录
if [[ -n "$tmp_dir" && -f "${tmp_dir}/docker-compose.yml" ]]; then
    if [[ -n "$dockerdb_dir" ]]; then
        target_dir="${dockerdb_dir}/bash"
        # 如果目标目录不存在则创建
        if [[ ! -d "$target_dir" ]]; then
            mkdir -p "$target_dir" 2>/dev/null
        fi
        # 复制文件（覆盖已存在的文件）
        if cp "${tmp_dir}/docker-compose.yml" "${target_dir}/docker-compose.yml" 2>/dev/null; then
            echo "已将 docker-compose.yml 存储到: ${target_dir}/docker-compose.yml"
	    echo "提示：如有因网络问题未能完成部署的，请到${target_dir}手动执行 'docker compose up -d' 命令。"
        else
            echo "警告：复制 docker-compose.yml 到 ${target_dir} 失败"
        fi
    else
        echo "警告：dockerdb_dir 变量未定义，无法备份 docker-compose.yml"
    fi
else
    echo "未找到 docker-compose.yml 文件，跳过备份"
fi

# 2. 处理 sshd_config
SSHD_CONFIG="/etc/ssh/sshd_config"
if [[ -f "$SSHD_CONFIG" ]]; then
    # 备份原文件
    cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
    # 删除 PermitRootLogin 相关行
    sed -i '/^[[:space:]]*PermitRootLogin/d' "$SSHD_CONFIG"
    echo "PermitRootLogin no" >> "$SSHD_CONFIG"
    echo "已设置 PermitRootLogin no"
    
    # 处理 AllowGroups / AllowUsers
    for directive in AllowUsers AllowGroups; do
        if grep -qi "^[[:space:]]*${directive}" "$SSHD_CONFIG"; then
            line=$(grep -i "^[[:space:]]*${directive}" "$SSHD_CONFIG" | head -1)
            line="${line%%#*}"
            if [[ "$line" =~ \broot\b ]]; then
                newline=$(echo "$line" | sed -E 's/\broot\b[, ]*//g' | sed -E 's/[, ]+$//')
                if [[ -z "$newline" ]] || [[ "$newline" =~ ^[[:space:]]*${directive}[[:space:]]*$ ]]; then
                    sed -i "s/^[[:space:]]*${directive}.*/#&/" "$SSHD_CONFIG"
                    echo "已注释掉空的 $directive 行"
                else
                    sed -i "s/^[[:space:]]*${directive}.*/$newline/" "$SSHD_CONFIG"
                    echo "已从 $directive 中删除 root"
                fi
            fi
        fi
    done
    
    # 删除 Port 22 行
    if grep -E "^[[:space:]]*Port[[:space:]]+22" "$SSHD_CONFIG" > /dev/null; then
        sed -i '/^[[:space:]]*Port[[:space:]]+22/d' "$SSHD_CONFIG"
        echo "已删除 Port 22 配置行"
    else
        echo "未找到 Port 22 配置行，无需删除"
    fi
    
    systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || echo "警告：无法重启ssh服务，请手动重启"
else
    echo "警告：$SSHD_CONFIG 不存在，跳过ssh配置检查"
fi

# 3. 网络检查：静态IP冲突提示
INTERFACES_FILE="/etc/network/interfaces"
if [[ -f "$INTERFACES_FILE" ]]; then
    static_ip=$(grep -E '^\s*address\s+' "$INTERFACES_FILE" | awk '{print $2}' | head -1)
    if [[ -n "$static_ip" ]]; then
        current_ip=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
        if [[ -n "$current_ip" && "$static_ip" != "$current_ip" ]]; then
            echo "提示：/etc/network/interfaces 中配置的静态IP ($static_ip) 与当前IP ($current_ip) 不一致。"
            echo "      系统重启网络后将切换到 $static_ip。如需立即切换，请手动执行: ifdown <网卡> && ifup <网卡>"
        elif [[ -z "$current_ip" ]]; then
            echo "提示：无法获取当前IPv4地址，请检查网络"
        else
            echo "静态IP配置与当前IP一致 ($static_ip)"
        fi
    else
        echo "未在 $INTERFACES_FILE 中找到静态 address 配置，跳过IP冲突检查"
    fi
else
    echo "警告：$INTERFACES_FILE 不存在，跳过网络检查"
fi

# 4. 删除临时目录 .tmp
if [[ -n "$tmp_dir" && -d "$tmp_dir" ]]; then
    rm -rf "$tmp_dir"
    echo "已删除临时目录: $tmp_dir"
else
    current_dir="$(pwd)"
    parent_dir="$(dirname "$current_dir")"
    possible_tmp="${parent_dir}/.tmp"
    if [[ -d "$possible_tmp" ]]; then
        rm -rf "$possible_tmp"
        echo "已删除临时目录: $possible_tmp"
    else
        echo "警告：找不到临时目录，跳过删除"
    fi
fi

echo "退出前检查完成。"
