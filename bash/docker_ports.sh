#!/bin/bash
# ============================================================
# 脚本：docker_ports.sh
# 功能：动态检测运行中的 Docker 容器及端口映射，管理 ufw 规则（仅开放至局域网）
#       1. 查看正在运行的容器及开放端口
#       2. 开放单个容器端口
#       3. 关闭单个容器端口
#       4. 开放所有容器端口
#       5. 关闭所有容器端口
# 用法：由 main.sh 调用，作为二级菜单“管理docker端口”
# ============================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}>>>${NC} $1"; }
log_warn()  { echo -e "${YELLOW}>>>${NC} $1"; }
log_error() { echo -e "${RED}>>>${NC} $1"; }

# 获取局域网网段（/24）
get_lan_subnet() {
    local iface=$(ip route show default | awk '{print $5}' | head -1)
    if [ -z "$iface" ]; then
        iface=$(ip -o link show | awk -F': ' '$2 != "lo" {print $2; exit}')
    fi
    if [ -z "$iface" ]; then
        log_error "无法检测局域网接口"
        return 1
    fi
    local ip_cidr=$(ip -o -4 addr show dev "$iface" | awk '{print $4}' | head -1)
    if [ -z "$ip_cidr" ]; then
        log_error "无法获取接口 $iface 的 IPv4 地址"
        return 1
    fi
    local net=$(echo "$ip_cidr" | sed -E 's/([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+\/[0-9]+/\1.0\/24/')
    echo "$net"
}

# ==================== 核心解析函数（修复 host 模式识别） ====================
declare -A CONTAINER_SERVICE_MAP      # container_name -> service_name
declare -A CONTAINER_PORTS_MAP        # container_name -> "host_port:proto host_port:proto ..."
declare -A CONTAINER_HOST_MODE_MAP    # container_name -> true/false

parse_compose_config() {
    local compose_file="${tmp_dir}/docker-compose.yml"
    if [[ ! -f "$compose_file" ]]; then
        log_error "找不到 docker-compose.yml 文件，请先执行「选择要部署的服务」生成 compose 文件。"
        return 1
    fi

    # 清空数组
    CONTAINER_SERVICE_MAP=()
    CONTAINER_PORTS_MAP=()
    CONTAINER_HOST_MODE_MAP=()

    # 读取整个文件到数组
    local lines=()
    mapfile -t lines < "$compose_file"
    local total=${#lines[@]}

    # 找出所有 container_name: 行及其位置
    declare -A container_lines
    for ((i=0; i<total; i++)); do
        if [[ "${lines[i]}" =~ ^[[:space:]]+container_name:[[:space:]]+([a-zA-Z0-9_-]+)$ ]]; then
            local cname="${BASH_REMATCH[1]}"
            container_lines["$cname"]=$i
        fi
    done

    # 对每个容器，向上找服务名，向下找端口和 host 模式
    for cname in "${!container_lines[@]}"; do
        local line_num=${container_lines["$cname"]}

        # 1. 向上找服务名
        local service_name=""
        for ((j=line_num-1; j>=0; j--)); do
            local prev_line="${lines[j]}"
            if [[ "$prev_line" =~ ^[[:space:]]{2}[a-zA-Z0-9_-]+:[[:space:]]*$ ]]; then
                service_name=$(echo "$prev_line" | sed -E 's/^[[:space:]]{2}([a-zA-Z0-9_-]+):.*$/\1/')
                break
            fi
        done
        if [[ -z "$service_name" ]]; then
            log_warn "无法为容器 $cname 找到对应的服务名，跳过"
            continue
        fi
        CONTAINER_SERVICE_MAP["$cname"]="$service_name"

        # 2. 查找当前服务的结束行
        local end_line=$total
        for ((k=line_num+1; k<total; k++)); do
            if [[ "${lines[k]}" =~ ^[[:space:]]+container_name:[[:space:]]+ ]]; then
                end_line=$k
                break
            fi
        done

        # 3. 检查 host 模式（修复：允许空格和引号）
        local is_host_mode=false


	# 3. 检查 host 模式
	local is_host_mode=false
	for ((k=line_num+1; k<end_line; k++)); do
    	    if [[ "${lines[k]}" =~ ^[[:space:]]+network_mode:[[:space:]]+[\"]?host[\"]?$ ]]; then
        	is_host_mode=true
        	break
    	    fi
    	done
        if [[ "$is_host_mode" == "true" ]]; then
            CONTAINER_HOST_MODE_MAP["$cname"]="true"
            CONTAINER_PORTS_MAP["$cname"]=""
            continue
        fi

        # 4. 查找 ports 块并提取端口映射
        local ports_found=()
        local in_ports_block=false
        for ((k=line_num+1; k<end_line; k++)); do
            local current_line="${lines[k]}"
            if [[ "$current_line" =~ ^[[:space:]]+ports:[[:space:]]*$ ]]; then
                in_ports_block=true
                continue
            fi
            if $in_ports_block; then
                # 检测块结束
                if [[ "$current_line" =~ ^[[:space:]]+[a-zA-Z_-]+: ]]; then
                    in_ports_block=false
                    continue
                fi
                # 提取端口映射
                if [[ "$current_line" =~ ^[[:space:]]+-[[:space:]]*\"?([0-9]+):[0-9]+(/?(tcp|udp))?\"? ]]; then
                    local host_port="${BASH_REMATCH[1]}"
                    local proto="${BASH_REMATCH[2]:-tcp}"
                    proto="${proto#/}"
                    ports_found+=("$host_port:$proto")
                elif [[ "$current_line" =~ ^[[:space:]]+-[[:space:]]*([0-9]+):[0-9]+(/?(tcp|udp))? ]]; then
                    local host_port="${BASH_REMATCH[1]}"
                    local proto="${BASH_REMATCH[2]:-tcp}"
                    proto="${proto#/}"
                    ports_found+=("$host_port:$proto")
                fi
            fi
        done
        if [[ ${#ports_found[@]} -gt 0 ]]; then
            CONTAINER_PORTS_MAP["$cname"]="${ports_found[*]}"
        else
            CONTAINER_PORTS_MAP["$cname"]=""
        fi
    done

    return 0
}
# ========================================================

# 获取当前运行中的容器列表
_get_running_containers() {
    docker ps --format "{{.Names}}" | sort
}

# 查看正在运行的容器及开放端口（修复显示和对齐）
_view_running_ports() {
    echo -e "\n${GREEN}>>> 查看正在运行的容器及开放端口${NC}"
    local running=($(_get_running_containers))
    if [[ ${#running[@]} -eq 0 ]]; then
        log_error "没有检测到任何运行中的容器"
        return
    fi

    parse_compose_config

    # 获取 ufw 规则中的端口信息（使用 verbose 模式以显示注释）
    declare -A CONTAINER_UFW_PORTS
    while IFS= read -r line; do
        if [[ "$line" =~ \#\ Docker:\ ([a-zA-Z0-9_-]+) ]]; then
            local cname="${BASH_REMATCH[1]}"
            if [[ "$line" =~ ^([0-9]+)/(tcp|udp) ]]; then
                local port="${BASH_REMATCH[1]}"
                local proto="${BASH_REMATCH[2]}"
                CONTAINER_UFW_PORTS["$cname"]="${CONTAINER_UFW_PORTS[$cname]} $port/$proto"
            elif [[ "$line" =~ ^([0-9]+)[[:space:]] ]]; then
                local port="${BASH_REMATCH[1]}"
                CONTAINER_UFW_PORTS["$cname"]="${CONTAINER_UFW_PORTS[$cname]} $port/tcp"
            fi
        fi
    done < <(ufw status verbose 2>/dev/null | grep -i "# Docker:")

    # 使用空格固定宽度对齐（第一列24字符，第二列40字符）
    printf "${YELLOW}%-24s %-40s${NC}\n" "容器名称" "开放端口（宿主机端口/协议）"
    echo "----------------------------------------"
    for container in "${running[@]}"; do
        if [[ "${CONTAINER_HOST_MODE_MAP[$container]}" == "true" ]]; then
            printf "%-24s %-40s\n" "$container" "Host模式，请自行管理"
        else
            local ports="${CONTAINER_UFW_PORTS[$container]}"
            if [[ -z "$ports" ]]; then
                printf "%-24s %-40s\n" "$container" "未开放任何端口"
            else
                local unique_ports=$(echo "$ports" | tr ' ' '\n' | sort -u | tr '\n' ' ')
                printf "%-24s %-40s\n" "$container" "$unique_ports"
            fi
        fi
    done
    echo "----------------------------------------"
}

# 为单个容器开放端口（仅局域网）
_open_ports_for_container() {
    local container="$1"
    local lan_subnet="$2"
    local ports_entry="${CONTAINER_PORTS_MAP[$container]}"
    if [[ -z "$ports_entry" ]]; then
        log_warn "容器 $container 没有定义端口映射或未解析到端口"
        return 1
    fi
    for entry in $ports_entry; do
        local host_port="${entry%:*}"
        local proto="${entry#*:}"
        log_info "开放端口 $host_port/$proto 至局域网 $lan_subnet (容器: $container)"
        ufw allow from "$lan_subnet" to any port "$host_port" proto "$proto" comment "Docker: $container" >/dev/null 2>&1
    done
    log_info "已为容器 $container 开放端口"
}

# 关闭单个容器的所有端口规则
_close_ports_for_container() {
    local container="$1"
    local rules_to_delete=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*\[([0-9]+)\] ]] && echo "$line" | grep -qi "Docker: $container"; then
            rules_to_delete+=("${BASH_REMATCH[1]}")
        fi
    done < <(ufw status numbered 2>/dev/null)
    if [[ ${#rules_to_delete[@]} -eq 0 ]]; then
        log_info "未找到容器 $container 的端口规则"
        return 0
    fi
    for ((i=${#rules_to_delete[@]}-1; i>=0; i--)); do
        echo "y" | ufw delete "${rules_to_delete[$i]}" >/dev/null 2>&1
        log_info "已删除规则 ${rules_to_delete[$i]}"
    done
    log_info "已关闭容器 $container 的所有端口规则"
    return 0
}

# 交互式开放单个容器端口
_open_single_port() {
    echo -e "\n${GREEN}>>> 开放单个容器端口${NC}"
    if ! parse_compose_config; then
        read -p "按 Enter 键返回..."
        return
    fi
    local running=($(_get_running_containers))
    if [[ ${#running[@]} -eq 0 ]]; then
        log_error "没有检测到任何运行中的容器，请先部署容器"
        read -p "按 Enter 键返回..."
        return
    fi

    local matched=()
    for container in "${running[@]}"; do
        if [[ -n "${CONTAINER_SERVICE_MAP[$container]}" ]]; then
            matched+=("$container")
        fi
    done
    if [[ ${#matched[@]} -eq 0 ]]; then
        log_error "没有找到与当前 compose 文件匹配的运行中容器"
        read -p "按 Enter 键返回..."
        return
    fi

    echo -e "${YELLOW}请选择要开放端口的容器：${NC}"
    for i in "${!matched[@]}"; do
        echo "  $((i+1))) ${matched[$i]} (服务: ${CONTAINER_SERVICE_MAP[${matched[$i]}]})"
    done
    echo "  b) 返回"
    read -p "请选择 [数字或b]: " sel
    if [[ "$sel" =~ ^[Bb]$ ]]; then
        return
    fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#matched[@]}" ]; then
        log_warn "无效选择"
        read -p "按 Enter 键返回..."
        return
    fi
    local target="${matched[$((sel-1))]}"
    if [[ "${CONTAINER_HOST_MODE_MAP[$target]}" == "true" ]]; then
        log_warn "容器 $target 使用了 host 网络模式，无法自动开放端口。"
        echo "请手动检查并配置防火墙规则。"
        read -p "按 Enter 键返回..."
        return
    fi
    local ports_entry="${CONTAINER_PORTS_MAP[$target]}"
    if [[ -z "$ports_entry" ]]; then
        log_warn "容器 $target 没有可用的端口映射"
        read -p "按 Enter 键返回..."
        return
    fi
    local lan_subnet=$(get_lan_subnet)
    if [[ -z "$lan_subnet" ]]; then
        log_error "无法获取局域网网段，请检查网络配置"
        read -p "按 Enter 键返回..."
        return
    fi
    echo -e "\n${YELLOW}即将为容器 $target 开放以下端口至局域网 $lan_subnet：${NC}"
    for entry in $ports_entry; do
        echo "  ${entry%:*}/${entry#*:}"
    done
    read -p "确认开放？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消操作"
        return
    fi
    _open_ports_for_container "$target" "$lan_subnet"
    ufw reload >/dev/null 2>&1
    log_info "端口开放完成"
    read -p "按 Enter 键返回..."
}

# 交互式关闭单个容器端口
_close_single_port() {
    echo -e "\n${GREEN}>>> 关闭单个容器端口${NC}"
    local containers_with_rules=()
    while IFS= read -r line; do
        if [[ "$line" =~ Docker:[[:space:]]+([a-zA-Z0-9_-]+) ]]; then
            local cname="${BASH_REMATCH[1]}"
            if [[ ! " ${containers_with_rules[@]} " =~ " ${cname} " ]]; then
                containers_with_rules+=("$cname")
            fi
        fi
    done < <(ufw status numbered 2>/dev/null | grep -i "Docker:")
    if [[ ${#containers_with_rules[@]} -eq 0 ]]; then
        log_info "没有找到任何已开放端口的容器规则"
        read -p "按 Enter 键返回..."
        return
    fi
    echo -e "${YELLOW}以下容器当前有端口规则：${NC}"
    for i in "${!containers_with_rules[@]}"; do
        echo "  $((i+1))) ${containers_with_rules[$i]}"
    done
    echo "  b) 返回"
    read -p "请选择要关闭端口的容器 [数字或b]: " sel
    if [[ "$sel" =~ ^[Bb]$ ]]; then
        return
    fi
    if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#containers_with_rules[@]}" ]; then
        log_warn "无效选择"
        read -p "按 Enter 键返回..."
        return
    fi
    local target="${containers_with_rules[$((sel-1))]}"
    echo -e "${YELLOW}即将关闭容器 $target 的所有端口规则${NC}"
    read -p "确认关闭？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消操作"
        return
    fi
    _close_ports_for_container "$target"
    ufw reload >/dev/null 2>&1
    log_info "关闭完成"
    read -p "按 Enter 键返回..."
}

# 开放所有匹配容器的端口
_open_all_ports() {
    echo -e "\n${GREEN}>>> 开放所有运行中容器的端口${NC}"
    if ! parse_compose_config; then
        read -p "按 Enter 键返回..."
        return
    fi
    local running=($(_get_running_containers))
    if [[ ${#running[@]} -eq 0 ]]; then
        log_error "没有检测到任何运行中的容器，请先部署容器"
        read -p "按 Enter 键返回..."
        return
    fi

    local to_open=()
    for container in "${running[@]}"; do
        if [[ -n "${CONTAINER_SERVICE_MAP[$container]}" ]] && [[ "${CONTAINER_HOST_MODE_MAP[$container]}" != "true" ]] && [[ -n "${CONTAINER_PORTS_MAP[$container]}" ]]; then
            to_open+=("$container")
        fi
    done
    if [[ ${#to_open[@]} -eq 0 ]]; then
        log_info "没有找到可自动开放端口的容器（可能是 host 网络或无端口映射）"
        read -p "按 Enter 键返回..."
        return
    fi
    local lan_subnet=$(get_lan_subnet)
    if [[ -z "$lan_subnet" ]]; then
        log_error "无法获取局域网网段，请检查网络配置"
        read -p "按 Enter 键返回..."
        return
    fi
    echo -e "${YELLOW}即将为以下容器开放端口至局域网 $lan_subnet：${NC}"
    for c in "${to_open[@]}"; do
        echo "  - $c (${CONTAINER_SERVICE_MAP[$c]})"
    done
    read -p "确认开放所有端口？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消操作"
        return
    fi
    for c in "${to_open[@]}"; do
        _open_ports_for_container "$c" "$lan_subnet"
    done
    ufw reload >/dev/null 2>&1
    log_info "所有匹配容器的端口已开放"
    read -p "按 Enter 键返回..."
}

# 关闭所有容器的端口规则
_close_all_ports() {
    echo -e "\n${GREEN}>>> 关闭所有容器的端口规则${NC}"
    local rules_to_delete=()
    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*\[([0-9]+)\] ]] && echo "$line" | grep -qi "Docker:"; then
            rules_to_delete+=("${BASH_REMATCH[1]}")
        fi
    done < <(ufw status numbered 2>/dev/null)
    if [[ ${#rules_to_delete[@]} -eq 0 ]]; then
        log_info "没有找到任何带 'Docker:' 注释的 ufw 规则"
        read -p "按 Enter 键返回..."
        return
    fi
    echo -e "${YELLOW}即将删除以下规则：${NC}"
    for num in "${rules_to_delete[@]}"; do
        ufw status numbered | grep -E "\[$num\]" | sed 's/^/  /'
    done
    read -p "确认删除所有 Docker 容器端口规则？(y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消删除"
        return
    fi
    for ((i=${#rules_to_delete[@]}-1; i>=0; i--)); do
        echo "y" | ufw delete "${rules_to_delete[$i]}" >/dev/null 2>&1
        log_info "已删除规则 ${rules_to_delete[$i]}"
    done
    ufw reload >/dev/null 2>&1
    log_info "所有 Docker 容器端口规则已关闭"
    read -p "按 Enter 键返回..."
}

# 主菜单
manage_container_ports_menu() {
    while true; do
        echo -e "\n${BLUE}======== 管理 Docker 容器端口 ========${NC}"
        echo "1) 查看正在运行的容器及开放端口"
        echo "2) 开放单个容器端口"
        echo "3) 关闭单个容器端口"
        echo "4) 开放所有容器端口"
        echo "5) 关闭所有容器端口"
        echo "b) 返回上级菜单"
        echo "=========================================="
        read -p "请选择: " manage_choice

        case "$manage_choice" in
            1) _view_running_ports ;;
            2) _open_single_port ;;
            3) _close_single_port ;;
            4) _open_all_ports ;;
            5) _close_all_ports ;;
            b|B) return ;;
            *) log_warn "无效选择，请输入 1-5 或 b" ;;
        esac
        echo -e "\n${YELLOW}按 Enter 键继续...${NC}"
        read
    done
}

manage_container_ports_menu
