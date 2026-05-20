#!/bin/bash
# 检查是否以 root 或 sudo 运行
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 用户或 sudo 执行此脚本。"
    exit 1
fi

#############################基本定义############################
# 获取脚本所在目录的绝对路径（动态）
maintain_dir=$(cd "$(dirname "$0")" && pwd)
# 定义 command 目录
command_dir="${maintain_dir}/command"

# 获取完整时间戳
time=$(date +%Y-%m-%d-%H:%M)
# 获取今天几号
day=$(date +%-d)
# 获取星期几（1=星期一，7=星期日）
weekday=$(date +%u)
# 获取当前小时（24小时制，范围 00-23）
hour=$(date +%H)

# 初始化数组，用于记录实际操作
actions=()
# 指定log文件
log_file="${maintain_dir}/bash_history.log"

# 使用更严格的检查（但允许命令失败，避免过早退出）
set -uo pipefail

# 记录操作（仅追加到数组）
record_action() {
    actions+=("$1")
}

# 退出时统一写入日志
write_final_log() {
    if [ ${#actions[@]} -gt 0 ]; then
        local suffix=$(IFS=_ ; echo "${actions[*]}")
        echo "{$time}_${suffix}_auto" >> "$log_file" 2>/dev/null || true
    fi
}
trap write_final_log EXIT

###########################以下为具体操作#########################

# 切换到 command 目录
cd "$command_dir" || exit

# 周日凌晨两点备份
if [ "$weekday" -eq 7 ] && [ "$hour" -eq 2 ]; then
    bash system_conf_backup.bash || true
    bash docker_db_backup.bash || true
    record_action "backup"
fi

# 开机时或凌晨2点挂载
# 切换对应目录
cd "$command_dir/mount" || exit

uptime_sec=$(cut -d. -f1 /proc/uptime)
if [ "$uptime_sec" -lt 300 ]; then
    sleep 10
    bash "smb.bash" || true
    record_action "mount_reboot"
elif [ "$hour" -eq 2 ]; then
    bash "smb.bash" || true
    record_action "mount_nightly"
fi

# 回到 command 目录
cd "$command_dir" || exit

# 每月1号清理超过180天的日志
if [ "$day" -eq 1 ] && [ -f "$log_file" ]; then
    # 确定清理命令和操作标识
    if [ "$weekday" -eq 7 ]; then
        clear_cmd="bash clear_log.bash -f"
        action_suffix="clear_log_force"
    else
        clear_cmd="bash clear_log.bash"
        action_suffix="clear_log"
    fi

    if $clear_cmd; then
        record_action "$action_suffix"
    else
        record_action "${action_suffix}_failed"
    fi
fi

# 脚本正常结束，trap 会自动调用 write_final_log
