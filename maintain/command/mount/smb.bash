#!/bin/bash

# 获取本机所有非回环的 IPv4 地址
get_local_ips() {
    # 使用 ip addr 或 ifconfig 提取 IP，排除 127.0.0.1 和 docker 网桥（可自行调整）
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | sort -u
}

# 将本机 IP 列表存入数组
mapfile -t local_ips < <(get_local_ips)

# 检查给定 IP 是否为本机 IP
is_local_ip() {
    local ip="$1"
    for local_ip in "${local_ips[@]}"; do
        if [[ "$ip" == "$local_ip" ]]; then
            return 0
        fi
    done
    return 1
}

# 从共享路径中提取主机 IP 或域名（格式：//host/share）
extract_host() {
    local share="$1"
    local tmp="${share#//}"      # 去掉开头的 //
    echo "${tmp%%/*}"            # 取第一个 / 之前的部分
}

CONFIG_FILE="smb.conf"

while read -r share mountpoint username password; do
    # 跳过空行或注释行
    [[ -z "$share" || "$share" =~ ^# ]] && continue

    # 提取主机地址
    host=$(extract_host "$share")

    # 检查是否为本机 IP
    if is_local_ip "$host"; then
        echo "Skipping local host: $host (share: $share)"
        continue
    fi

    echo -n "Checking connectivity to $host ... "
    # ping 测试：发送1个包，超时5秒
    if ping -c 1 -W 5 "$host" > /dev/null 2>&1; then
        echo "OK"
        # 创建挂载点目录（如果不存在）
        mkdir -p "$mountpoint"
        # 执行挂载
        echo "Mounting $share to $mountpoint"
        mount -t cifs "$share" "$mountpoint" -o "username=$username,password=$password"
        if [ $? -eq 0 ]; then
            echo "Mount successful"
        else
            echo "Mount failed"
        fi
    else
        echo "FAILED (timeout or unreachable), skipping this line"
    fi
done < "$CONFIG_FILE"

# Restart Jellyfin
docker restart jellyfin
