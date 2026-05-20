#!/bin/bash
# 脚本：partition.sh (最终完整版)
# 功能：磁盘分区与挂载管理，支持增量分区，保护关键系统分区
# 依赖：parted, lsblk, blkid, numfmt, wipefs

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}>>>${NC} $1"; }
log_warn()  { echo -e "${YELLOW}>>>${NC} $1"; }
log_error() { echo -e "${RED}>>>${NC} $1"; }

CRITICAL_MOUNTS=("/" "/boot" "/boot/efi" "swap")

is_critical_partition() {
    local dev="$1"
    for mnt in "${CRITICAL_MOUNTS[@]}"; do
        if [[ "$mnt" == "swap" ]]; then
            if swapon --show=NAME 2>/dev/null | grep -q "^${dev}$"; then
                return 0
            fi
        else
            local mounted=$(findmnt -n -o TARGET "$dev" 2>/dev/null)
            if [[ "$mounted" == "$mnt" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

check_deps() {
    local missing=()
    command -v parted &>/dev/null || missing+=("parted")
    command -v numfmt &>/dev/null || missing+=("coreutils")
    command -v blkid &>/dev/null || missing+=("util-linux")
    command -v wipefs &>/dev/null || missing+=("util-linux")
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "安装必要软件包: ${missing[*]}"
        apt update -qq && apt install -y "${missing[@]}"
    fi
}

backup_fstab() {
    if [ ! -f /etc/fstab.bak ]; then
        cp /etc/fstab /etc/fstab.bak
        log_info "已备份 /etc/fstab 到 /etc/fstab.bak"
    fi
}

get_all_disks() {
    local disks=()
    while read -r name size type; do
        [ "$type" != "disk" ] && continue
        disks+=("/dev/$name:$size")
    done < <(lsblk -d -n -o NAME,SIZE,TYPE)
    if [ ${#disks[@]} -eq 0 ]; then
        log_error "未找到任何硬盘"
        exit 1
    fi
    printf '%s\n' "${disks[@]}"
}

umount_noncritical_disk() {
    local disk="$1"
    local mounted=$(lsblk -ln -o NAME,MOUNTPOINT "$disk" | awk '$2!="" {print "/dev/"$1}')
    for part in $mounted; do
        if ! is_critical_partition "$part"; then
            umount "$part" && log_info "已卸载 $part"
        else
            log_warn "跳过卸载关键分区 $part"
        fi
    done
}

get_partition_dev() {
    local disk="$1"
    local part_num="$2"
    if [[ "$disk" =~ /dev/nvme[0-9]+n[0-9]+$ ]]; then
        echo "${disk}p${part_num}"
    else
        echo "${disk}${part_num}"
    fi
}

parse_size_to_mib() {
    local input="$1"
    input=$(echo "$input" | tr -d ' ')
    if [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
        return 0
    fi
    if [[ "$input" =~ ^([0-9]+)([KkMmGgTt])$ ]]; then
        local num=${BASH_REMATCH[1]}
        local unit=${BASH_REMATCH[2]}
        case $unit in
            K|k) echo $((num / 1024)) ;;
            M|m) echo "$num" ;;
            G|g) echo $((num * 1024)) ;;
            T|t) echo $((num * 1024 * 1024)) ;;
            *) return 1 ;;
        esac
        return 0
    fi
    return 1
}

get_free_space_parted() {
    local disk="$1"
    local free_spaces=()
    
    local total=$(parted -s "$disk" unit MiB print 2>/dev/null | grep "Disk /dev/" | sed -E 's/.* ([0-9]+)MiB/\1/')
    if [ -z "$total" ]; then
        log_error "无法获取磁盘大小"
        return 1
    fi
    
    local has_label=$(parted -s "$disk" print 2>&1 | grep -E "Partition Table: (gpt|msdos)" || true)
    if [ -z "$has_label" ]; then
        free_spaces+=("1:$((total - 1))")
        printf '%s\n' "${free_spaces[@]}"
        return 0
    fi
    
    local partitions=$(parted -s "$disk" unit MiB print 2>/dev/null | grep -E '^ [0-9]' | awk '{print $2, $3}')
    if [ -z "$partitions" ]; then
        free_spaces+=("1:$((total - 1))")
        printf '%s\n' "${free_spaces[@]}"
        return 0
    fi
    
    local last_end=1
    while read -r start_raw end_raw; do
        local start=$(echo "$start_raw" | sed -E 's/([0-9]+(\.[0-9]+)?)MiB/\1/')
        local end=$(echo "$end_raw" | sed -E 's/([0-9]+(\.[0-9]+)?)MiB/\1/')
        start=$(printf "%.0f" "$start" 2>/dev/null || echo "$start")
        end=$(printf "%.0f" "$end" 2>/dev/null || echo "$end")
        if [[ "$start" =~ ^[0-9]+$ ]] && [[ "$end" =~ ^[0-9]+$ ]]; then
            if [ $start -gt $last_end ]; then
                local free_start=$last_end
                local free_size=$((start - last_end))
                if [ $free_size -gt 0 ]; then
                    free_spaces+=("$free_start:$free_size")
                fi
            fi
            last_end=$((end + 1))
        else
            log_warn "无法解析分区起始/结束: $start_raw $end_raw"
        fi
    done <<< "$partitions"
    
    if [ $last_end -lt $total ]; then
        free_spaces+=("$last_end:$((total - last_end))")
    fi
    
    printf '%s\n' "${free_spaces[@]}"
}

create_partition_parted() {
    local disk="$1"
    local start_mib="$2"
    local end_value="$3"   # 可以是数字或 "100%"
    log_info "使用 parted 创建分区: 起始 ${start_mib}MiB, 结束 ${end_value}"
    
    local has_label=$(parted -s "$disk" print 2>&1 | grep -E "Partition Table: (gpt|msdos)" || true)
    if [ -z "$has_label" ]; then
        log_info "磁盘没有分区表，创建 GPT 标签..."
        parted -s "$disk" mklabel gpt
        udevadm settle
        sleep 1
    fi
    
    if ! parted -s "$disk" unit MiB mkpart primary ext4 ${start_mib} ${end_value}; then
        log_error "parted 创建分区失败"
        return 1
    fi
    
    udevadm settle
    partprobe "$disk" 2>/dev/null || true
    sleep 2
    return 0
}

clear_and_single_partition() {
    local disk="$1"
    local mnt="$2"
    log_info "清除全盘并创建单个分区..."
    wipefs -a --force "$disk" 2>/dev/null || true
    dd if=/dev/zero of="$disk" bs=1M count=1 conv=notrunc 2>/dev/null || true
    parted -s "$disk" mklabel gpt
    parted -s "$disk" unit MiB mkpart primary ext4 1 100%
    udevadm settle
    partprobe "$disk" 2>/dev/null || true
    sleep 2
    
    local part_dev=$(get_partition_dev "$disk" 1)
    for i in {1..20}; do
        if [ -b "$part_dev" ]; then break; fi
        sleep 0.5
    done
    if [ ! -b "$part_dev" ]; then
        log_error "分区设备 $part_dev 未出现"
        return 1
    fi
    
    mkfs.ext4 -F "$part_dev" >/dev/null
    log_info "格式化 $part_dev 为 ext4"
    mkdir -p "$mnt"
    local uuid=$(blkid -s UUID -o value "$part_dev")
    if [ -z "$uuid" ]; then
        log_error "无法获取 $part_dev 的 UUID"
        return 1
    fi
    echo "# $mnt was on $part_dev" >> /etc/fstab
    echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
    if mount "$part_dev" "$mnt"; then
        log_info "已挂载 $part_dev 到 $mnt"
    else
        log_error "挂载失败，请手动检查"
        return 1
    fi
}

create_new_partition_in_free() {
    local disk="$1"
    local free_spaces=()
    mapfile -t free_spaces < <(get_free_space_parted "$disk")
    if [ ${#free_spaces[@]} -eq 0 ]; then
        log_error "磁盘 $disk 上没有可用的空闲空间"
        return 1
    fi
    
    echo -e "\n${GREEN}磁盘 $disk 上的空闲区域：${NC}"
    local idx=1
    declare -A free_map
    for space in "${free_spaces[@]}"; do
        IFS=':' read -r start_mib size_mib <<< "$space"
        echo "  $idx) 起始: ${start_mib} MiB, 大小: ${size_mib} MiB"
        free_map[$idx]="$space"
        ((idx++))
    done
    echo "  b) 返回上级菜单"
    
    while true; do
        read -p "请选择空闲区域序号（或 b 返回）: " choice
        if [[ "$choice" =~ ^[Bb]$ ]]; then
            return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ $choice -ge 1 ] && [ $choice -lt $idx ]; then
            break
        else
            log_warn "无效选择"
        fi
    done
    
    IFS=':' read -r start_mib max_size_mib <<< "${free_map[$choice]}"
    echo -n "新分区大小（默认占满该区域，支持单位如 10G、500M）: "
    read -r size_input
    local size_mib=$max_size_mib
    if [ -n "$size_input" ]; then
        local parsed=$(parse_size_to_mib "$size_input")
        if [ $? -eq 0 ] && [ -n "$parsed" ]; then
            if [ $parsed -gt $max_size_mib ]; then
                log_warn "大小超过空闲区域，将使用最大可用 ${max_size_mib} MiB"
                size_mib=$max_size_mib
            else
                size_mib=$parsed
            fi
        else
            log_error "大小格式错误"
            return 1
        fi
    fi
    
    read -p "挂载点绝对路径: " mnt
    while [[ ! "$mnt" =~ ^/ ]]; do
        log_warn "挂载点必须以 / 开头"
        read -p "挂载点: " mnt
    done
    
    # 如果选择占满整个空闲区域，使用 "100%" 避免边界计算错误
    local end_value
    if [ $size_mib -eq $max_size_mib ]; then
        end_value="100%"
    else
        end_value=$((start_mib + size_mib))
    fi
    
    local before=$(parted -s "$disk" print 2>/dev/null | grep -c "^ [0-9]" || echo 0)
    
    if ! create_partition_parted "$disk" "$start_mib" "$end_value"; then
        return 1
    fi
    
    local after=$(parted -s "$disk" print 2>/dev/null | grep -c "^ [0-9]" || echo 0)
    if [ $after -le $before ]; then
        log_error "分区创建失败"
        return 1
    fi
    local last_part_num=$(parted -s "$disk" print 2>/dev/null | awk '/^ [0-9]/ {print $1}' | tail -1)
    if [ -z "$last_part_num" ]; then
        log_error "无法获取新分区编号"
        return 1
    fi
    
    local part_dev=$(get_partition_dev "$disk" "$last_part_num")
    if [[ "$part_dev" == "$disk" ]]; then
        log_error "分区设备名无效"
        return 1
    fi
    
    for i in {1..20}; do
        if [ -b "$part_dev" ]; then break; fi
        sleep 0.5
    done
    if [ ! -b "$part_dev" ]; then
        log_error "分区设备 $part_dev 未出现"
        return 1
    fi
    
    mkfs.ext4 -F "$part_dev" >/dev/null
    log_info "格式化 $part_dev 为 ext4"
    
    mkdir -p "$mnt"
    local uuid=$(blkid -s UUID -o value "$part_dev")
    if [ -z "$uuid" ]; then
        log_error "无法获取 UUID"
        return 1
    fi
    
    echo "# $mnt was on $part_dev" >> /etc/fstab
    echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
    if mount "$part_dev" "$mnt"; then
        log_info "已挂载 $part_dev 到 $mnt"
    else
        log_error "挂载失败，请手动检查"
        return 1
    fi
}

config_disk() {
    local disk="$1"
    local size_h="$2"
    log_info "===== 开始配置硬盘 $disk ($size_h) ====="
    umount_noncritical_disk "$disk"
    
    echo -e "\n${BLUE}请选择操作方式：${NC}"
    echo "  1) 在剩余空间创建新分区（保留已有数据）"
    echo "  2) 清除全盘所有分区并创建单个分区（数据将全部丢失）"
    echo "  b) 返回"
    read -p "请选择 (1/2/b): " mode
    
    case "$mode" in
        1)
            create_new_partition_in_free "$disk"
            ;;
        2)
            read -p "请输入挂载点（如 /mnt/data）: " mnt
            while [[ ! "$mnt" =~ ^/ ]]; do
                log_warn "挂载点必须以 / 开头"
                read -p "挂载点: " mnt
            done
            clear_and_single_partition "$disk" "$mnt"
            ;;
        b|B)
            log_info "返回上级菜单"
            return 0
            ;;
        *)
            log_warn "无效选择"
            return 1
            ;;
    esac
    log_info "$disk 配置成功"
}

format_and_mount() {
    check_deps
    backup_fstab
    local disks=()
    mapfile -t disks < <(get_all_disks)
    while true; do
        echo -e "\n${GREEN}可用的硬盘：${NC}"
        for i in "${!disks[@]}"; do
            echo "  $((i+1))) ${disks[$i]}"
        done
        echo "  b) 返回"
        read -p "选择硬盘编号: " choice
        if [[ "$choice" =~ ^[Bb]$ ]]; then
            return
        elif [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#disks[@]} ]; then
            idx=$((choice-1))
            disk_info="${disks[$idx]}"
            disk="${disk_info%:*}"
            size_h="${disk_info#*:}"
            config_disk "$disk" "$size_h"
        else
            log_warn "无效选择"
        fi
    done
}

mount_existing_partitions() {
    check_deps
    backup_fstab
    local parts=()
    local part_sizes=()
    local all_disks=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')
    for disk in $all_disks; do
        while IFS= read -r line; do
            eval "$line"
            if [ "$FSTYPE" = "ext4" ] && [ -z "$MOUNTPOINT" ]; then
                local part_dev="/dev/$NAME"
                if is_critical_partition "$part_dev"; then
                    log_warn "跳过关键分区 $part_dev"
                    continue
                fi
                parts+=("$part_dev")
                part_sizes+=("$SIZE")
            fi
        done < <(lsblk -P -o NAME,FSTYPE,MOUNTPOINT,SIZE "$disk" 2>/dev/null)
    done
    if [ ${#parts[@]} -eq 0 ]; then
        log_error "未找到任何可用的 ext4 分区（未挂载且非关键分区）"
        log_info "返回上级菜单"
        return 1
    fi
    echo -e "\n${GREEN}找到以下可挂载的 ext4 分区：${NC}"
    for i in "${!parts[@]}"; do
        echo "  $((i+1))) ${parts[$i]} 大小: ${part_sizes[$i]}"
    done
    echo "  q) 退出"
    while true; do
        read -p "请选择要挂载的分区序号（或 q 退出）: " sel
        if [[ "$sel" =~ ^[Qq]$ ]]; then
            break
        fi
        if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#parts[@]} ]; then
            log_warn "无效选择"
            continue
        fi
        local idx=$((sel-1))
        local part_dev="${parts[$idx]}"
        if is_critical_partition "$part_dev"; then
            log_error "拒绝挂载关键分区 $part_dev"
            continue
        fi
        local cur_mount=$(findmnt -n -o TARGET "$part_dev" 2>/dev/null)
        if [ -n "$cur_mount" ]; then
            log_warn "$part_dev 已经挂载到 $cur_mount"
            continue
        fi
        local uuid=$(blkid -s UUID -o value "$part_dev")
        if [ -z "$uuid" ]; then
            log_error "无法获取 UUID"
            continue
        fi
        local default_mnt="/mnt/$(basename "$part_dev")"
        read -p "挂载点绝对路径 [默认: $default_mnt]: " mnt
        if [ -z "$mnt" ]; then
            mnt="$default_mnt"
        fi
        while [[ ! "$mnt" =~ ^/ ]]; do
            read -p "挂载点（必须以 / 开头）: " mnt
        done
        mkdir -p "$mnt"
        if ! grep -q "^UUID=$uuid " /etc/fstab; then
            echo "# $mnt was on $part_dev" >> /etc/fstab
            echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
            log_info "已添加 $mnt 到 /etc/fstab"
        fi
        mount "$part_dev" "$mnt"
        log_info "成功挂载 $part_dev 到 $mnt"
    done
}

show_self_menu() {
    while true; do
        echo
        echo "========== 磁盘分区与挂载工具 =========="
        echo "1. 挂载已有分区"
        echo "2. 格式化/分区磁盘"
        echo "e. 退出"
        echo "========================================"
        read -p "请选择: " choice
        case "$choice" in
            1) mount_existing_partitions ;;
            2) format_and_mount ;;
            e|E) exit 0 ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -eq 0 ]; then
        show_self_menu
    else
        case "$1" in
            --mount-existing) mount_existing_partitions ;;
            --format) format_and_mount ;;
            *) echo "用法: $0 [--mount-existing|--format]"; exit 1 ;;
        esac
    fi
fi
