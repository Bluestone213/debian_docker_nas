#!/bin/bash

# 检查root权限
if [[ $EUID -ne 0 ]]; then
    echo "错误：此脚本需要root权限才能运行。请使用sudo或切换到root用户。"
    exit 1
fi

# 定义初始目录（脚本所在目录）
original_bash_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
original_pwd="$(pwd)"

# bash_dir：当前目录下的子目录 bash
bash_dir="${original_pwd}/bash"

# config_dir：当前目录下的子目录 config
config_dir="${original_pwd}/config"

# 预设相关变量
Nas_Hostname=""
special_config="N"
type="L"
json_dir=""
json_file=""
PRESET_IMPORTED=0
tmp_dir=""
dockerdb_dir=""

# 辅助函数：运行$bash_dir下的脚本
run_script() {
    local script_name="$1"
    shift
    local script_path="${bash_dir}/${script_name}"
    if [[ ! -f "$script_path" ]]; then
        echo "错误：找不到脚本 $script_path"
        return 1
    fi
    local current_dir="$(pwd)"
    cd "$bash_dir" || { echo "错误：无法切换到目录 $bash_dir"; return 1; }
    echo ">>> 执行: bash $script_name $* (工作目录: $bash_dir)"
    bash "$script_name" "$@"
    local ret=$?
    cd "$current_dir"
    return $ret
}

# 运行临时目录中的脚本（用于基础配置、安装docker、退出检查等）
run_tmp_script() {
    local script_name="$1"
    shift
    if [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]]; then
        echo "错误：临时目录未准备好。请先执行「2.导入配置文件」或「3.手动输入配置」。"
        return 1
    fi
    local script_path="${tmp_dir}/${script_name}"
    if [[ ! -f "$script_path" ]]; then
        echo "错误：找不到脚本 $script_path"
        return 1
    fi
    local current_dir="$(pwd)"
    cd "$tmp_dir" || { echo "错误：无法切换到目录 $tmp_dir"; return 1; }
    echo ">>> 执行: bash $script_name $* (工作目录: $tmp_dir)"
    bash "$script_name" "$@"
    local ret=$?
    cd "$current_dir"
    return $ret
}

# 准备临时目录 .tmp，并将 bash/ 下的所有 .sh 文件复制进去
prepare_tmp_dir() {
    tmp_dir="${original_pwd}/.tmp"
    if [[ -d "$tmp_dir" ]]; then
        rm -rf "$tmp_dir"
    fi
    mkdir -p "$tmp_dir" || { echo "错误：无法创建临时目录 $tmp_dir"; return 1; }
    if [[ ! -d "$bash_dir" ]]; then
        echo "错误：目录 $bash_dir 不存在，无法复制脚本文件。"
        return 1
    fi
    cp "${bash_dir}"/*.sh "$tmp_dir/" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "警告：复制脚本文件时出现问题，请确认 $bash_dir 下存在 .sh 文件。"
    else
        echo "已将所有脚本复制到临时目录：$tmp_dir"
    fi
    return 0
}

# 一键执行所有基础配置
run_all_basic() {
    if [[ $PRESET_IMPORTED -eq 0 ]]; then
        echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
        return 1
    fi
    if [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]]; then
        echo "错误：临时目录未准备好。请重新导入配置或手动输入配置。"
        return 1
    fi
    echo "开始执行所有基础配置..."
    run_tmp_script "basic_config.sh" --json "$json_file" --all
    echo "所有基础配置执行完毕。"
}

# ========== 拷贝并初始化配置维护脚本（新增配置备份） ==========
submenu_maintain() {
    if [[ $PRESET_IMPORTED -eq 0 ]]; then
        echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
        return 1
    fi
    if [[ -z "$dockerdb_dir" ]]; then
        echo "错误：dockerdb_dir 未定义，请检查配置。"
        return 1
    fi

    # 1. 处理 JSON 配置文件：删除三个密码字段，保存到 origin_conf 目录
    local origin_conf_dir="${dockerdb_dir}/bash/origin_conf"
    mkdir -p "$origin_conf_dir" 2>/dev/null || {
        echo "错误：无法创建目录 $origin_conf_dir"
        return 1
    }
    local target_json="${origin_conf_dir}/$(hostname).json"
    if [[ -n "$json_file" && -f "$json_file" ]]; then
        # 确保 jq 已安装
        if ! command -v jq &> /dev/null; then
            echo "正在安装 jq（JSON 处理工具）..."
            apt update -qq && apt install -y jq
        fi
        # 使用 jq 精确删除密码字段
        jq 'del(.Nas_Admin_passwd, .Nas_Root_passwd, .Nas_User_smbpasswd)' "$json_file" > "$target_json" 2>/dev/null
        if [[ $? -eq 0 ]]; then
            echo "已将当前配置（已删除密码字段）保存到: $target_json"
        else
            echo "警告：使用 jq 处理 JSON 失败，请检查 JSON 文件格式。"
        fi
    else
        echo "警告：未找到当前配置文件 (\$json_file)，跳过配置备份"
    fi

    # 2. 复制 maintain 文件夹（静默）
    local target_base="${dockerdb_dir}/bash"
    local target_dir="${target_base}/maintain"
    local source_dir="${original_bash_dir}/maintain"

    mkdir -p "$target_base" 2>/dev/null || {
        echo "错误：无法创建目录 $target_base"
        return 1
    }

    if [[ ! -d "$source_dir" ]]; then
        echo "错误：源目录 $source_dir 不存在，无法复制。"
        return 1
    fi
    # 如果目标已存在，先删除（确保完整覆盖）
    if [[ -d "$target_dir" ]]; then
        rm -rf "$target_dir"
    fi
    cp -r "$source_dir" "$target_dir" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        echo "错误：复制 maintain 文件夹失败。"
        return 1
    fi
    echo "维护脚本已复制到 $target_dir"

    # 3. 检查 init.bash 并运行
    if [[ ! -f "$target_dir/init.bash" ]]; then
        echo "错误：$target_dir/init.bash 不存在，无法初始化。"
        return 1
    fi

    cd "$target_dir" || { echo "错误：无法切换到 $target_dir"; return 1; }
    bash init.bash
    local ret=$?
    cd - > /dev/null

    if [ $ret -ne 0 ]; then
        echo "错误：init.bash 执行失败（退出码 $ret）。"
        return 1
    fi
    return 0
}

# 一级菜单
show_main_menu() {
    echo
    echo "========== 主菜单 =========="
    echo "1. 磁盘分区与挂载"
    echo "2. 导入配置文件"
    echo "3. 手动输入配置"
    echo "4. 基础配置"
    echo "5. 安装docker环境"
    echo "6. 部署docker容器"
    echo "7. 管理docker端口"
    echo "8. 拷贝并初始化配置维护脚本"
    echo "e. 退出脚本"
    echo "============================"
    echo -n "请选择: "
}

# 二级菜单 - 磁盘分区与挂载
submenu_disk() {
    while true; do
        echo
        echo "-------- 磁盘分区与挂载 --------"
        echo "1. 挂载已有分区"
        echo "2. 格式化磁盘并挂载"
        echo "b. 返回上一级"
        echo "------------------------------"
        echo -n "请选择: "
        read -r disk_choice
        case "$disk_choice" in
            1)
                run_script "partition.sh" "--mount-existing"
                ;;
            2)
                run_script "partition.sh" "--format"
                ;;
            b|B)
                break
                ;;
            *)
                echo "无效选择，请重新输入。"
                ;;
        esac
    done
}

# 二级菜单 - 基础配置（调用 basic_config.sh 不同子任务）
submenu_basic() {
    while true; do
        echo
        echo "-------- 基础配置 --------"
        echo "1. 一键执行所有任务"
        echo "2. 系统与用户信息"
        echo "3. 镜像源与软件"
        echo "4. 防火墙基础配置"
        echo "5. 开放SMB共享"
        echo "6. 网络配置（固定IP）"
        echo "b. 返回上一级"
        echo "--------------------------"
        echo -n "请选择: "
        read -r sub_choice
        case "$sub_choice" in
            1)
                run_all_basic
                ;;
            2)
                if [[ $PRESET_IMPORTED -eq 0 ]]; then
                    echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
                else
                    run_tmp_script "basic_config.sh" --json "$json_file" --system
                fi
                ;;
            3)
                if [[ $PRESET_IMPORTED -eq 0 ]]; then
                    echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
                else
                    run_tmp_script "basic_config.sh" --json "$json_file" --mirror
                fi
                ;;
            4)
                if [[ $PRESET_IMPORTED -eq 0 ]]; then
                    echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
                else
                    run_tmp_script "basic_config.sh" --json "$json_file" --ufw
                fi
                ;;
            5)
                if [[ $PRESET_IMPORTED -eq 0 ]]; then
                    echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
                else
                    run_tmp_script "basic_config.sh" --json "$json_file" --smb
                fi
                ;;
            6)
                if [[ $PRESET_IMPORTED -eq 0 ]]; then
                    echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
                else
                    run_tmp_script "basic_config.sh" --json "$json_file" --net
                fi
                ;;
            b|B) break ;;
            *) echo "无效选择，请重新输入。" ;;
        esac
    done
}

# 二级菜单 - 部署docker容器
submenu_deploy() {
    if [[ $PRESET_IMPORTED -eq 0 ]]; then
        echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
        read -p "按 Enter 键返回..."
        return
    fi
    if [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]]; then
        echo "错误：临时目录未准备好。请重新导入配置。"
        read -p "按 Enter 键返回..."
        return
    fi
    if [[ ! -f "${tmp_dir}/docker_deploy.sh" ]]; then
        echo "错误：找不到 docker_deploy.sh，请检查脚本完整性。"
        read -p "按 Enter 键返回..."
        return
    fi
    run_tmp_script "docker_deploy.sh"
}

# 二级菜单 - 管理docker端口
submenu_port() {
    if [[ $PRESET_IMPORTED -eq 0 ]]; then
        echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
        read -p "按 Enter 键返回..."
        return
    fi
    if [[ -z "$tmp_dir" || ! -d "$tmp_dir" ]]; then
        echo "错误：临时目录未准备好。请重新导入配置。"
        read -p "按 Enter 键返回..."
        return
    fi
    if [[ ! -f "${tmp_dir}/docker_ports.sh" ]]; then
        echo "错误：找不到 docker_ports.sh，请检查脚本完整性。"
        read -p "按 Enter 键返回..."
        return
    fi
    run_tmp_script "docker_ports.sh"
}

# 主程序循环
while true; do
    show_main_menu
    read -r main_choice
    case "$main_choice" in
        1) submenu_disk ;;
        2)
            if [[ -f "${bash_dir}/load.sh" ]]; then
                export config_dir
                source "${bash_dir}/load.sh"
                if [[ $PRESET_IMPORTED -eq 1 ]]; then
                    if prepare_tmp_dir; then
                        export tmp_dir
                    else
                        echo "错误：准备临时目录失败，后续功能可能无法使用。"
                    fi
                    export Nas_Hostname special_config type json_dir json_file bash_dir dockerdb_dir PRESET_IMPORTED
                    echo "预设导入成功。当前工作目录: $bash_dir"
                    echo "主机名: $Nas_Hostname, 特殊配置: $special_config, 类型: $type"
                    echo "JSON文件路径: $json_file"
                fi
            else
                echo "错误：找不到 ${bash_dir}/load.sh，请检查脚本完整性。"
            fi
            ;;
        3)
            # 调用交互式配置向导
            if [[ -f "${bash_dir}/input.sh" ]]; then
                source "${bash_dir}/input.sh"
            else
                echo "错误：找不到 ${bash_dir}/input.sh，请检查脚本完整性。"
            fi
            ;;
        4) submenu_basic ;;
        5)
            if [[ $PRESET_IMPORTED -eq 0 ]]; then
                echo "错误：请先执行「2.导入配置文件」或「3.手动输入配置」加载配置信息。"
            else
                run_tmp_script "docker_install.sh" "--${json_file}"
            fi
            ;;
        6) submenu_deploy ;;
        7) submenu_port ;;
        8) submenu_maintain ;;
        e|E)
            echo "正在执行退出检查..."
            if [[ -n "$tmp_dir" && -d "$tmp_dir" && -f "${tmp_dir}/check.sh" ]]; then
                run_tmp_script "check.sh"
            else
                echo "警告：临时目录未准备或 check.sh 不存在，跳过退出检查。"
            fi
            echo "脚本已退出。"
            exit 0
            ;;
        *) echo "无效选择，请重新输入。" ;;
    esac
done
