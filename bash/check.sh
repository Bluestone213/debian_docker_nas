#!/bin/bash
# 退出前检查：优先处理 docker 相关，后处理 ssh、网络、清理临时目录

echo "===== 执行退出前检查 ====="

# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

# ========== 1. 安装数据备份：备份 docker-compose.yml 和当前配置 json（优化：检查文件新旧） ==========
if [[ -n "$dockerdb_dir" ]]; then
    backup_dir="${dockerdb_dir}/bash/origin_conf"
    mkdir -p "$backup_dir" 2>/dev/null
    if [[ ! -d "$backup_dir" ]]; then
        echo "警告：无法创建备份目录 $backup_dir"
    else
        # 1.1 备份 docker-compose.yml（检查文件是否在2小时内，是则跳过）
        docker_compose_src="${tmp_dir}/docker-compose.yml"
        docker_compose_dst="${backup_dir}/docker-compose.yml"
        need_copy=true
        if [[ -f "$docker_compose_dst" ]]; then
            # 获取文件修改时间戳（秒）
            dst_mtime=$(stat -c %Y "$docker_compose_dst" 2>/dev/null)
            current_time=$(date +%s)
            if [[ -n "$dst_mtime" ]] && (( current_time - dst_mtime < 7200 )); then
                echo "docker-compose.yml 备份文件已在2小时内创建，跳过复制。"
                need_copy=false
            else
                echo "docker-compose.yml 备份文件已存在但超过2小时，将重新复制。"
            fi
        fi
        if [[ "$need_copy" == true ]] && [[ -f "$docker_compose_src" ]]; then
            if cp "$docker_compose_src" "$docker_compose_dst" 2>/dev/null; then
                echo "已将 docker-compose.yml 备份到: $docker_compose_dst"
                echo "提示：如有因网络问题未能完成部署的，请到${backup_dir}手动执行 'docker compose up -d' 命令。"
            else
                echo "警告：复制 docker-compose.yml 到 ${backup_dir} 失败"
            fi
        elif [[ ! -f "$docker_compose_src" ]]; then
            echo "未找到 docker-compose.yml 文件，跳过备份"
        fi

        # 1.2 导出当前配置 json（删除密码字段，检查目标文件新旧）
        if [[ -n "$json_file" && -f "$json_file" ]]; then
            target_json="${backup_dir}/${Nas_Hostname}.json"
            need_export=true
            if [[ -f "$target_json" ]]; then
                dst_mtime=$(stat -c %Y "$target_json" 2>/dev/null)
                current_time=$(date +%s)
                if [[ -n "$dst_mtime" ]] && (( current_time - dst_mtime < 7200 )); then
                    echo "配置文件 $target_json 已在2小时内创建，跳过导出。"
                    need_export=false
                else
                    echo "配置文件已存在但超过2小时，将重新导出。"
                fi
            fi
            if [[ "$need_export" == true ]]; then
                # 删除三个密码字段的行
                sed -e '/"Nas_Admin_passwd"/d' \
                    -e '/"Nas_Root_passwd"/d' \
                    -e '/"Nas_User_smbpasswd"/d' \
                    "$json_file" > "$target_json" 2>/dev/null
                if [[ $? -eq 0 && -f "$target_json" ]]; then
                    echo "已将当前配置导出到: $target_json (已删除密码字段)"
                else
                    echo "警告：导出配置 json 失败"
                fi
            fi
        else
            echo "警告：未找到当前配置文件 (\$json_file)，跳过配置备份"
        fi
    fi
else
    echo "警告：dockerdb_dir 未定义，无法进行安装数据备份"
fi

# ========== 2. 新增：检查并复制 maintain 维护脚本文件夹 ==========
maintain_src="${SCRIPT_DIR}/maintain"
maintain_dst="${dockerdb_dir}/bash/maintain"
if [[ -n "$dockerdb_dir" ]]; then
    echo "---- 检查维护脚本文件夹 ----"
    need_copy_maintain=true
    if [[ -d "$maintain_dst" ]]; then
        dst_mtime=$(stat -c %Y "$maintain_dst" 2>/dev/null)
        current_time=$(date +%s)
        if [[ -n "$dst_mtime" ]] && (( current_time - dst_mtime < 7200 )); then
            echo "维护脚本文件夹 $maintain_dst 已在2小时内创建，跳过复制。"
            need_copy_maintain=false
        else
            echo "维护脚本文件夹已存在但超过2小时，将删除后重新复制。"
            rm -rf "$maintain_dst"
        fi
    fi
    if [[ "$need_copy_maintain" == true ]]; then
        if [[ -d "$maintain_src" ]]; then
            cp -r "$maintain_src" "$maintain_dst"
            echo "维护脚本已复制到 $maintain_dst"
        else
            echo "警告：源维护脚本目录不存在 ($maintain_src)，无法复制。"
        fi
    fi
else
    echo "警告：dockerdb_dir 未定义，跳过维护脚本检查"
fi

# ========== 3. 处理 sshd_config（原第2项，顺延为3） ==========
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
            # 更可靠的 root 单词匹配（支持空格、逗号、行首行尾）
            if grep -qE '(^|[[:space:],])root($|[[:space:],])' <<< "$line"; then
                newline=$(echo "$line" | sed -E 's/(^|[[:space:],])root([[:space:],]|$)/\1\2/g' | sed -E 's/[, ]+$//' | sed -E 's/[[:space:]]+/ /g')
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
    
    # 删除 Port 22 行（使用 -E 支持 +）
    if grep -E "^[[:space:]]*Port[[:space:]]+22" "$SSHD_CONFIG" > /dev/null; then
        sed -i -E '/^[[:space:]]*Port[[:space:]]+22/d' "$SSHD_CONFIG"
        echo "已删除 Port 22 配置行"
    else
        echo "未找到 Port 22 配置行，无需删除"
    fi
    
    systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null || echo "警告：无法重启ssh服务，请手动重启"
else
    echo "警告：$SSHD_CONFIG 不存在，跳过ssh配置检查"
fi

# ========== 4. 网络检查：静态IP冲突提示（原第3项，顺延为4） ==========
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

# ========== 5. 删除临时目录 .tmp（原第4项，顺延为5） ==========
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
