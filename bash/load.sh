#!/bin/bash
# 此脚本通过 source 方式被 main.sh 调用，用于从 config_dir 中选择 JSON 预设文件并设置环境变量
# 增加对 special_config 和 type 合法值的警告检查

if [[ -z "$bash_dir" ]]; then
    echo "错误：bash_dir 未定义，请从主程序调用此脚本。"
    return 1 2>/dev/null || exit 1
fi

if [[ -z "$config_dir" ]]; then
    echo "错误：config_dir 未定义，请从主程序调用此脚本。"
    return 1 2>/dev/null || exit 1
fi

# 解析 JSON 中的 ###HOST### 区块
parse_host_block() {
    local json_file="$1"
    local block=$(sed -n '/###HOST###/,/###HOST###/p' "$json_file" | grep -v '###HOST###')
    block=$(echo "$block" | sed 's/#.*//')
    local key value
    while IFS= read -r line; do
        if [[ "$line" =~ \"([^\"]+)\"[[:space:]]*:[[:space:]]*\"([^\"]+)\" ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            case "$key" in
                Nas_Hostname) Nas_Hostname="$value" ;;
                special_config) special_config="$value" ;;
                type) type="$value" ;;
                dockerdb_dir) dockerdb_dir="$value" ;;
            esac
        fi
    done <<< "$block"
}

# 列出 config_dir 下的所有 .json 文件
list_json_files() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        echo "警告：配置目录 $dir 不存在，将使用默认配置。"
        return 1
    fi
    mapfile -t json_files < <(find "$dir" -maxdepth 1 -name "*.json" -type f | sort)
    if [[ ${#json_files[@]} -eq 0 ]]; then
        echo "警告：配置目录 $dir 中没有找到 .json 文件，将使用默认配置。"
        return 1
    fi
    return 0
}

# 显示菜单并让用户选择
select_json_file() {
    local dir="$1"
    echo "从配置目录 $dir 中选择 JSON 文件："
    local i=1
    for f in "${json_files[@]}"; do
        echo "  $i) $(basename "$f")"
        ((i++))
    done
    echo "  0) 使用默认配置 (default.json)"
    echo -n "请选择 [0-${#json_files[@]}], 直接回车默认使用 default.json: "
    read -r choice
    if [[ -z "$choice" ]]; then
        json_file="${dir}/default.json"
        echo "已选择默认文件: $json_file"
    elif [[ "$choice" == "0" ]]; then
        json_file="${dir}/default.json"
        echo "已选择默认文件: $json_file"
    elif [[ "$choice" =~ ^[1-9][0-9]*$ ]] && [[ $choice -le ${#json_files[@]} ]]; then
        json_file="${json_files[$((choice-1))]}"
        echo "已选择: $(basename "$json_file")"
    else
        echo "无效选择，将使用默认配置 default.json"
        json_file="${dir}/default.json"
    fi
}

# 主流程
json_files=()
if list_json_files "$config_dir"; then
    select_json_file "$config_dir"
else
    json_file="${config_dir}/default.json"
    echo "将使用默认配置文件: $json_file"
fi

if [[ ! -f "$json_file" ]]; then
    echo "错误：配置文件 $json_file 不存在，请检查。"
    return 1 2>/dev/null || exit 1
fi

if ! parse_host_block "$json_file"; then
    echo "错误：解析JSON中的###HOST###区块失败，请检查文件格式。"
    return 1 2>/dev/null || exit 1
fi

# 设置默认值
Nas_Hostname=${Nas_Hostname:-"未知主机"}
special_config=${special_config:-"N"}
type=${type:-"L"}
dockerdb_dir=${dockerdb_dir:-"/mnt/database"}

# 检查 special_config 合法性（Y/N/D）
case "$special_config" in
    Y|N|D) ;;
    *) echo "警告：special_config 值 '$special_config' 不合法，应为 Y、N 或 D。已保留原值。" ;;
esac
# 检查 type 合法性（L/H）
case "$type" in
    L|H) ;;
    *) echo "警告：type 值 '$type' 不合法，应为 L 或 H。已保留原值。" ;;
esac

# 导出变量
json_dir="$(cd "$(dirname "$json_file")" && pwd)"
json_file="$json_dir/$(basename "$json_file")"
export json_dir json_file Nas_Hostname special_config type dockerdb_dir

PRESET_IMPORTED=1
export PRESET_IMPORTED

echo "成功导入预设："
echo "  Nas_Hostname = $Nas_Hostname"
echo "  special_config = $special_config"
echo "  type = $type"
echo "  dockerdb_dir = $dockerdb_dir"
echo "  JSON文件路径 = $json_file"
