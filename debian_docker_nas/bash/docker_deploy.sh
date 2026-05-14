#!/bin/bash
# ============================================================
# 脚本：docker_deploy.sh
# 功能：Docker 部署管理
#       1. 快捷部署（基于类型）
#       2. 选择要部署的服务（生成 compose 文件）
#       3. 手动修复特定容器参数（生成后必选）
#       4. 下载镜像（基于已生成的 compose 文件）
#       5. 部署容器（基于已生成的 compose 文件）
# 说明：生成的 compose 文件中的宿主机路径前缀 /database/ 会替换为 $dockerdb_dir 的实际值
#       部署操作设置600秒超时，超时则自动终止并清理残留进程。
#       部署前会将临时目录文件备份到 ${dockerdb_dir}/bash 下。
#       部署时切换到 ${dockerdb_dir}/bash 目录执行。
#       下载镜像时启用并行（最多10个并行任务）。
# ============================================================

set -e

# ---------------------------- 依赖检查 ----------------------------
check_deps() {
    if ! command -v whiptail &> /dev/null; then
        apt-get update && apt-get install -y whiptail
    fi
    if ! command -v docker &> /dev/null; then
        echo "错误: Docker 未安装"
        exit 1
    fi
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        echo "错误: docker-compose 未安装"
        exit 1
    fi
}

get_compose_cmd() {
    command -v docker-compose &> /dev/null && echo "docker-compose" || echo "docker compose"
}

# ---------------------------- 公共函数 ----------------------------
extract_services() {
    local file="$1"
    grep -E '^  [a-zA-Z0-9_-]+:$' "$file" | sed -E 's/^  ([a-zA-Z0-9_-]+):$/\1/'
}

# 询问并更新 dockerdb_dir（展示当前值，用户可修改；若目录不存在则询问创建）
prompt_dockerdb_dir() {
    local default_dir="${dockerdb_dir:-/mnt/database}"
    echo "当前 Docker 持久化目录: $default_dir"
    echo -n "是否更改？(y/N): "
    read -r change_ans
    if [[ "$change_ans" =~ ^[Yy]$ ]]; then
        while true; do
            echo -n "请输入新的持久化目录（绝对路径）: "
            read -r new_dir
            if [[ -z "$new_dir" ]]; then
                echo "输入为空，保持原值: $dockerdb_dir"
                break
            fi
            if [[ -d "$new_dir" ]]; then
                dockerdb_dir="$new_dir"
                echo "已更新持久化目录为: $dockerdb_dir"
                break
            else
                echo "目录 $new_dir 不存在。"
                echo -n "是否创建？(y/n): "
                read -r create_ans
                if [[ "$create_ans" =~ ^[Yy]$ ]]; then
                    mkdir -p "$new_dir" && {
                        dockerdb_dir="$new_dir"
                        echo "目录已创建，已更新持久化目录为: $dockerdb_dir"
                        break
                    } || {
                        echo "创建目录失败，请重新输入。"
                        continue
                    }
                else
                    echo "请重新输入一个存在的目录。"
                    continue
                fi
            fi
        done
    else
        echo "保持原值: $dockerdb_dir"
    fi
    export dockerdb_dir
}

# 替换卷路径中的 /database 为实际 dockerdb_dir 值
replace_volumes_path() {
    local compose_file="$1"
    local target_dir="${dockerdb_dir:-/mnt/database}"
    sed -i "s|/database/|${target_dir}/|g" "$compose_file"
    sed -i "s|/database:|${target_dir}:|g" "$compose_file"
}

# 备份 docker-compose.yml 到持久化目录下的 bash 子目录（静默执行）
backup_tmp_to_persist() {
    local target_base="${dockerdb_dir:-/mnt/database}"
    local target_dir="${target_base}/bash"
    if [[ ! -d "$target_dir" ]]; then
        mkdir -p "$target_dir" 2>/dev/null || return 0
    fi
    if [[ -f "${tmp_dir}/docker-compose.yml" ]]; then
        cp -f "${tmp_dir}/docker-compose.yml" "${target_dir}/docker-compose.yml" 2>/dev/null || true
    fi
}

# 生成过滤后的 compose 文件（基于用户选择的服务，用于交互式）
generate_filtered_compose() {
    local selected_services=("$@")
    local cfg_dir="${config_dir:-$(pwd)/config}"
    local compose_l="${cfg_dir}/docker_compose_L.yml"
    local compose_h="${cfg_dir}/docker_compose_H.yml"
    local tmp_dir_="${tmp_dir:-/tmp/docker_compose_tmp}"
    local full_file="${tmp_dir_}/full.yml"
    local output_file="${tmp_dir_}/docker-compose.yml"

    {
        echo "services:"
        tail -n +2 "$compose_l" 2>/dev/null || true
        tail -n +2 "$compose_h" 2>/dev/null || true
    } > "$full_file"

    local filtered=$(mktemp)
    local in_block=0
    local current_service=""
    local current_block=""

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]{2}[a-zA-Z0-9_-]+:$ ]]; then
            if [ $in_block -eq 1 ] && [ -n "$current_block" ]; then
                if [[ " ${selected_services[*]} " == *" ${current_service} "* ]]; then
                    echo -n "$current_block" >> "$filtered"
                fi
            fi
            current_service=$(echo "$line" | sed -E 's/^[[:space:]]{2}([a-zA-Z0-9_-]+):$/\1/')
            current_block="$line"$'\n'
            in_block=1
        else
            if [ $in_block -eq 1 ]; then
                current_block+="$line"$'\n'
            fi
        fi
    done < "$full_file"

    if [ $in_block -eq 1 ] && [ -n "$current_block" ]; then
        if [[ " ${selected_services[*]} " == *" ${current_service} "* ]]; then
            echo -n "$current_block" >> "$filtered"
        fi
    fi

    {
        echo "services:"
        cat "$filtered"
    } > "$output_file"

    rm -f "$full_file" "$filtered"
    echo "$output_file"
}

# ---------------------------- 快捷部署 ----------------------------
quick_deploy() {
    # 设置 trap 捕获中断信号，确保返回菜单
    trap 'echo -e "\n部署被中断，返回菜单..."; return 1' INT TERM

    local current_type="${type:-L}"
    if [[ "$current_type" == "H" || "$current_type" == "h" ]]; then
        echo ">>> 快捷部署模式：重型部署（包含 L+H 全部服务）"
    else
        echo ">>> 快捷部署模式：轻型部署（仅 L 服务）"
    fi

    prompt_dockerdb_dir

    local cfg_dir="${config_dir:-$(pwd)/config}"
    local compose_l="${cfg_dir}/docker_compose_L.yml"
    local compose_h="${cfg_dir}/docker_compose_H.yml"
    local output_file="${tmp_dir}/docker-compose.yml"

    if [[ "$current_type" == "H" || "$current_type" == "h" ]]; then
        if [[ ! -f "$compose_l" ]] || [[ ! -f "$compose_h" ]]; then
            echo "错误：缺少必要的模板文件"
            trap - INT TERM
            return 1
        fi
        {
            echo "services:"
            tail -n +2 "$compose_l"
            tail -n +2 "$compose_h"
        } > "$output_file"
    else
        if [[ ! -f "$compose_l" ]]; then
            echo "错误：找不到模板文件 $compose_l"
            trap - INT TERM
            return 1
        fi
        {
            echo "services:"
            tail -n +2 "$compose_l"
        } > "$output_file"
    fi

    echo "已生成 compose 文件: $output_file"
    replace_volumes_path "$output_file"

    local special_script="${bash_dir:-$(dirname "$0")}/docker_special.sh"
    if [[ -f "$special_script" ]]; then
        echo ">>> 执行特殊容器参数修复..."
        bash "$special_script" "$output_file" "${special_config:-N}"
    else
        echo "警告：未找到 $special_script，跳过特殊配置"
    fi

    # 备份 docker-compose.yml 到持久化目录
    backup_tmp_to_persist

    # 切换到持久化目录下的 bash 子目录执行部署
    local deploy_dir="${dockerdb_dir}/bash"
    if [[ ! -d "$deploy_dir" ]]; then
        mkdir -p "$deploy_dir" || { echo "错误: 无法创建目录 $deploy_dir"; trap - INT TERM; return 1; }
    fi
    echo "切换到目录: $deploy_dir"
    cd "$deploy_dir" || { echo "错误: 无法切换到 $deploy_dir"; trap - INT TERM; return 1; }
    echo "执行: timeout --kill-after=10s 600 docker compose up -d (600秒超时，10秒后强制终止)"
    if timeout --kill-after=10s 600 docker compose up -d; then
        echo "容器部署成功。"
        echo "当前 Docker 持久化目录: $dockerdb_dir"
        trap - INT TERM
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "错误: 部署超时（600秒），已终止。正在清理残留进程..."
            echo "提示：如有因网络问题未能完成部署的，请到$deploy_dir手动执行 'docker compose up -d' 命令。"
	    pkill -f "docker compose" 2>/dev/null || true
        else
            echo "部署失败（退出码: $exit_code）。"
        fi
        trap - INT TERM
        return 1
    fi
}

# ---------------------------- 交互式选择服务 ----------------------------
generate_compose_interactive() {
    local cfg_dir="${config_dir:-$(pwd)/config}"
    local compose_l="${cfg_dir}/docker_compose_L.yml"
    local compose_h="${cfg_dir}/docker_compose_H.yml"
    if [ ! -f "$compose_l" ] && [ ! -f "$compose_h" ]; then
        echo "错误: 找不到任何模板文件"
        return 1
    fi

    local l_services=()
    local h_services=()
    if [ -f "$compose_l" ]; then
        mapfile -t l_services < <(extract_services "$compose_l")
    fi
    if [ -f "$compose_h" ]; then
        mapfile -t h_services < <(extract_services "$compose_h")
    fi

    local all_services=()
    local seen=()
    for s in "${l_services[@]}"; do
        all_services+=("$s"); seen+=("$s")
    done
    for s in "${h_services[@]}"; do
        if [[ ! " ${seen[*]} " == *" $s "* ]]; then
            all_services+=("$s"); seen+=("$s")
        fi
    done

    declare -A service_src
    for s in "${l_services[@]}"; do service_src["$s"]="L"; done
    for s in "${h_services[@]}"; do
        if [[ -z "${service_src[$s]}" ]]; then
            service_src["$s"]="H"
        fi
    done

    local current_type="${type:-L}"
    declare -A preselect
    for srv in "${all_services[@]}"; do
        src="${service_src[$srv]}"
        if [[ "$current_type" == "H" || "$current_type" == "h" ]]; then
            preselect["$srv"]="ON"
        else
            if [[ "$src" == "L" ]]; then
                preselect["$srv"]="ON"
            else
                preselect["$srv"]="OFF"
            fi
        fi
    done

    local whiptail_args=()
    for srv in "${all_services[@]}"; do
        local tag="[${service_src[$srv]}]"
        whiptail_args+=("$srv" "$tag" "${preselect[$srv]}")
    done

    local selected_raw
    selected_raw=$(whiptail --title "Docker 服务选择" \
        --checklist "请选择要部署的服务（空格键选择/取消）\n当前类型: $([ "$current_type" = "H" ] && echo "重型" || echo "轻型")" \
        20 60 10 "${whiptail_args[@]}" 3>&1 1>&2 2>&3)
    [ $? -ne 0 ] && { echo "用户取消"; return 1; }

    local selected_services=()
    eval "selected_services=($selected_raw)"
    [ ${#selected_services[@]} -eq 0 ] && { echo "未选择任何服务"; return 1; }

    echo "已选择的服务: ${selected_services[*]}"
    prompt_dockerdb_dir

    local output_file=$(generate_filtered_compose "${selected_services[@]}")
    replace_volumes_path "$output_file"

    echo "已生成 compose 文件: $output_file，卷路径中的 /database 已替换为实际持久化目录。"
    export GENERATED_COMPOSE_FILE="$output_file"
    return 0
}

menu_select_services() {
    echo ">>> 选择要部署的服务（生成 docker-compose.yml）"
    generate_compose_interactive && echo "compose 文件已生成并完成卷路径替换。" || echo "生成失败"
}

# ---------------------------- 手动修复特定容器参数 ----------------------------
menu_special_config() {
    local compose_file="${tmp_dir}/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        echo "错误: 找不到已生成的 docker-compose.yml 文件，请先执行「1.快捷部署」或「2.选择要部署的服务」。"
        return 1
    fi
    echo ">>> 手动修复特定容器参数"
    local special_script="${bash_dir:-$(dirname "$0")}/docker_special.sh"
    if [ ! -f "$special_script" ]; then
        echo "错误: 找不到 $special_script"
        return 1
    fi
    bash "$special_script" "$compose_file" "${special_config:-N}"
    echo "特殊配置处理完成。"
}

# ---------------------------- 下载镜像 ----------------------------
menu_pull_images() {
    # 确保 compose 文件已备份到持久化目录
    backup_tmp_to_persist

    local compose_file="${dockerdb_dir}/bash/docker-compose.yml"
    if [ ! -f "$compose_file" ]; then
        echo "错误: 找不到已生成的 docker-compose.yml 文件，请先执行「1.快捷部署」或「2.选择要部署的服务」。"
        return 1
    fi

    # 设置并行下载限制（最多10个并行任务）
    export COMPOSE_PARALLEL_LIMIT=10

    echo "使用 compose 文件: $compose_file"
    local compose_cmd=$(get_compose_cmd)
    echo "正在拉取所有镜像（超时600秒，并行拉取）... (按 Ctrl+C 中断)"
    # 使用 --parallel 标志启用并行拉取（Docker Compose V2 支持）
    if timeout 600 $compose_cmd -f "$compose_file" pull --parallel; then
        echo "所有镜像拉取成功。"
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "错误: 拉取镜像超时（600秒），已终止。"
        else
            echo "错误: 拉取失败或被中断。"
        fi
        return 1
    fi
}

# ---------------------------- 部署容器 ----------------------------
menu_deploy_containers() {
    # 设置 trap 捕获中断信号，确保返回菜单
    trap 'echo -e "\n部署被中断，返回菜单..."; return 1' INT TERM

    # 确保 compose 文件已备份到持久化目录
    backup_tmp_to_persist

    local deploy_dir="${dockerdb_dir}/bash"
    if [[ ! -d "$deploy_dir" ]]; then
        echo "错误: 目录 $deploy_dir 不存在，请先执行「1.快捷部署」或「2.选择要部署的服务」。"
        trap - INT TERM
        return 1
    fi
    if [[ ! -f "${deploy_dir}/docker-compose.yml" ]]; then
        echo "错误: 找不到 ${deploy_dir}/docker-compose.yml 文件，请先执行「1.快捷部署」或「2.选择要部署的服务」。"
        trap - INT TERM
        return 1
    fi

    # 设置并行拉取限制，加速部署时缺失镜像的拉取
    export COMPOSE_PARALLEL_LIMIT=10

    echo "切换到目录: $deploy_dir"
    cd "$deploy_dir" || { echo "错误: 无法切换到 $deploy_dir"; trap - INT TERM; return 1; }

    echo "执行: timeout --kill-after=10s 600 docker compose up -d (600秒超时，10秒后强制终止)"
    if timeout --kill-after=10s 600 docker compose up -d; then
        echo "容器部署成功。"
        echo "当前 Docker 持久化目录: $dockerdb_dir"
        trap - INT TERM
        return 0
    else
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            echo "错误: 部署超时（600秒），已终止。正在清理残留进程..."
	    echo "提示：如有因网络问题未能完成部署的，请到$deploy_dir手动执行 'docker compose up -d' 命令。"
            pkill -f "docker compose" 2>/dev/null || true
        else
            echo "部署失败（退出码: $exit_code）。"
        fi
        trap - INT TERM
        return 1
    fi
}

# ---------------------------- 主菜单 ----------------------------
main_menu() {
    while true; do
        echo
        echo "========== Docker 部署管理 =========="
        echo "1. 快捷部署（基于类型）"
        echo "2. 选择要部署的服务（生成 compose 文件）"
        echo "3. 手动修复特定容器参数（生成后必选）"
        echo "4. 下载镜像（基于已生成的 compose 文件）"
        echo "5. 部署容器（基于已生成的 compose 文件）"
        echo "b. 返回上级菜单"
        echo "====================================="
        echo -n "请选择: "
        read -r choice
        case "$choice" in
            1) quick_deploy ;;
            2) menu_select_services ;;
            3) menu_special_config ;;
            4) menu_pull_images ;;
            5) menu_deploy_containers ;;
            b|B) break ;;
            *) echo "无效选择，请重新输入。" ;;
        esac
    done
}

# ---------------------------- 主入口 ----------------------------
check_deps
if [[ -z "$type" ]]; then
    [[ -n "$json_file" && -f "$json_file" ]] && type=$(sed -n '/###HOST###/,/###HOST###/p' "$json_file" | grep -E '"type"[[:space:]]*:' | sed -E 's/.*"type"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/')
    type=${type:-L}
fi
[[ -z "$config_dir" ]] && config_dir="$(pwd)/config"
[[ -z "$tmp_dir" ]] && tmp_dir="/tmp/docker_compose_tmp" && mkdir -p "$tmp_dir"
export type config_dir tmp_dir dockerdb_dir

main_menu
