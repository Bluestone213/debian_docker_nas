#!/bin/bash
# 清理 bash_history.log 中超过指定天数的记录
# 用法: clear_log.bash [-f] [-t days]
#   -f        强制模式：扫描全文件，删除所有日期早于阈值的行（包括乱序的旧记录）
#   -t days   指定保留天数，默认180天
#   无参数：默认模式，仅删除文件开头的连续老记录（假设日志按时间有序）
# 检查是否以 root 或 sudo 运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户或 sudo 执行此脚本。"
    exit 1
fi

set -uo pipefail

# 默认值
force_mode=false
retain_days=180

# 解析参数
while getopts "ft:" opt; do
    case $opt in
        f) force_mode=true ;;
        t)
            if [[ "$OPTARG" =~ ^[0-9]+$ ]]; then
                retain_days=$OPTARG
            else
                echo "错误：-t 参数必须是正整数"
                exit 1
            fi
            ;;
        *) echo "用法: $0 [-f] [-t days]"; exit 1 ;;
    esac
done

# 获取脚本所在目录的绝对路径
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
maintain_dir=$(dirname "$SCRIPT_DIR")   # 上一级目录为 maintain 根目录
log_file="${maintain_dir}/bash_history.log"

if [[ ! -f "$log_file" ]]; then
    echo "日志文件 $log_file 不存在，跳过清理"
    exit 0
fi

# 计算阈值日期（保留天数前，格式 YYYY-MM-DD）
threshold=$(date -d "${retain_days} days ago" +%Y-%m-%d)
echo "阈值日期: $threshold (删除早于此日期的记录，保留最近 ${retain_days} 天)"

if [ "$force_mode" = false ]; then
    # ========== 默认模式：仅删除文件开头的连续老记录 ==========
    echo "使用默认模式（仅删除开头的连续老记录）..."
    
    first_keep_line=""
    while IFS=: read -r num line; do
        date_part=$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
        if [[ -n "$date_part" && ( "$date_part" > "$threshold" || "$date_part" == "$threshold" ) ]]; then
            first_keep_line=$num
            break
        fi
    done < <(grep -n -E '^\{[0-9]{4}-[0-9]{2}-[0-9]{2}' "$log_file")
    
    if [[ -n "$first_keep_line" && "$first_keep_line" -gt 1 ]]; then
        sed -i "1,$((first_keep_line - 1))d" "$log_file"
        echo "已删除前 $((first_keep_line - 1)) 行（早于 $threshold）"
    else
        echo "没有需要删除的连续开头记录"
    fi
else
    # ========== 强制模式：全文件扫描，删除所有超过阈值的行 ==========
    echo "使用强制模式（扫描全文，删除所有早于阈值的行）..."
    
    temp_file=$(mktemp)
    cleaned_count=0
    
    while IFS= read -r line; do
        if [[ "$line" =~ \{([0-9]{4}-[0-9]{2}-[0-9]{2}) ]]; then
            log_date="${BASH_REMATCH[1]}"
            if [[ "$log_date" < "$threshold" ]]; then
                ((cleaned_count++))
                continue
            fi
        fi
        echo "$line" >> "$temp_file"
    done < "$log_file"
    
    mv "$temp_file" "$log_file"
    echo "清理完成，共删除 $cleaned_count 行记录（早于 $threshold）"
fi
