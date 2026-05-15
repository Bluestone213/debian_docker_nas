#!/bin/bash
# 脚本：partition.sh
# 功能：
#   1. 挂载已有 ext4 分区（非系统盘）
#   2. 格式化磁盘并挂载（支持整盘一个分区或交互式多分区，仅 GPT）
# 用法：以 root 权限运行
#       独立运行：直接执行，显示菜单
#       被 main.sh 调用：支持 --mount-existing 和 --format 参数
# 依赖：sfdisk (util-linux), lsblk, blkid, numfmt, wipefs

set -e

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}>>>${NC} $1"; }
log_warn()  { echo -e "${YELLOW}>>>${NC} $1"; }
log_error() { echo -e "${RED}>>>${NC} $1"; }

# 检查并安装必要软件包
check_deps() {
    local missing=()
    command -v sfdisk &>/dev/null || missing+=("util-linux")
    command -v numfmt &>/dev/null || missing+=("coreutils")
    command -v blkid &>/dev/null || missing+=("util-linux")
    command -v wipefs &>/dev/null || missing+=("util-linux")
    if [ ${#missing[@]} -gt 0 ]; then
        log_info "安装必要软件包: ${missing[*]}"
        apt update -qq && apt install -y "${missing[@]}"
    fi
}

# 备份 fstab
backup_fstab() {
    if [ ! -f /etc/fstab.bak ]; then
        cp /etc/fstab /etc/fstab.bak
        log_info "已备份 /etc/fstab 到 /etc/fstab.bak"
    fi
}

# 获取系统盘（根目录所在磁盘）
get_system_disk() {
    local root_dev=$(findmnt -n -o SOURCE /)
    local root_disk=$(lsblk -no PKNAME "$root_dev" 2>/dev/null)
    if [ -z "$root_disk" ]; then
        if [[ "$root_dev" =~ ^/dev/[a-z]+$ ]]; then
            root_disk=$(basename "$root_dev")
        else
            log_error "无法确定系统盘"
            exit 1
        fi
    fi
    echo "/dev/$root_disk"
}

# 获取所有非系统盘（格式：/dev/sda:大小）
get_other_disks() {
    local sys_disk=$(get_system_disk)
    local disks=()
    while read -r name size type; do
        [ "$type" != "disk" ] && continue
        [ "/dev/$name" = "$sys_disk" ] && continue
        disks+=("/dev/$name:$size")
    done < <(lsblk -d -n -o NAME,SIZE,TYPE)
    if [ ${#disks[@]} -eq 0 ]; then
        log_error "未找到除系统盘以外的可用硬盘"
        exit 1
    fi
    printf '%s\n' "${disks[@]}"
}

# 卸载磁盘上所有挂载的分区
umount_disk() {
    local disk="$1"
    local mounted=$(lsblk -ln -o NAME,MOUNTPOINT "$disk" | awk '$2!="" {print "/dev/"$1}')
    for part in $mounted; do
        umount "$part" && log_info "已卸载 $part"
    done
}

# 清除分区表并初始化为 GPT（使用 wipefs + sfdisk）
clear_partition_table() {
    local disk="$1"
    
    local part_count=$(lsblk -ln -o NAME,TYPE "$disk" | grep -c "part$" || true)
    if [ "$part_count" -gt 0 ]; then
        log_warn "警告：磁盘 $disk 上检测到 ${part_count} 个现有分区！"
        log_warn "继续操作将清除所有分区并销毁其上所有数据。"
    fi
    
    read -p "是否清除 $disk 上的所有分区? (y/N): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
        wipefs -a "$disk" 2>/dev/null
        sfdisk "$disk" <<EOF >/dev/null 2>&1
label: gpt
EOF
        log_info "$disk 分区表已清空并重建为 GPT"
        return 0
    else
        log_info "保留现有分区表"
        return 1
    fi
}

# 模式1：整个磁盘一个分区
create_single_partition() {
    local disk="$1"
    local mnt="$2"

    log_info "创建整个磁盘的一个分区..."
    wipefs -a "$disk" 2>/dev/null || true
    sfdisk "$disk" <<EOF >/dev/null 2>&1
label: gpt
unit: MiB
start=1, size= , type=Linux
EOF
    udevadm settle

    local part_dev
    if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
        part_dev="${disk}p1"
    else
        part_dev="${disk}1"
    fi
    while [ ! -b "$part_dev" ]; do
        sleep 0.2
        udevadm settle
    done

    log_info "创建分区 $part_dev"
    mkfs.ext4 -F "$part_dev" >/dev/null
    log_info "格式化 $part_dev 为 ext4"

    mkdir -p "$mnt"
    local uuid=$(blkid -s UUID -o value "$part_dev")
    echo "# $mnt was on $part_dev" >> /etc/fstab
    echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
    log_info "已添加 $mnt 到 /etc/fstab"

    mount "$part_dev" "$mnt"
    log_info "已挂载 $part_dev 到 $mnt"
}

# 模式2：交互式分区
interactive_partition() {
    local disk="$1"
    local total_bytes=$(lsblk -b -d -n -o SIZE "$disk")
    local total_mib=$((total_bytes / 1024 / 1024))
    if [ -z "$total_mib" ] || [ "$total_mib" -eq 0 ]; then
        log_error "无法获取 $disk 容量"
        return 1
    fi
    echo "磁盘 $disk 总容量: ${total_mib} MiB"

    local parts=()
    local used_mib=0
    local part_num=1

    while true; do
        local remain_mib=$((total_mib - used_mib))
        if [ $remain_mib -le 0 ]; then
            log_info "剩余空间为 0，结束分区添加"
            break
        fi
        echo -e "\n${YELLOW}剩余空间: ${remain_mib} MiB${NC}"
        read -p "分区 $part_num 大小（如 10G, 500M, remain, done）: " size_input

        case "$size_input" in
            done|DONE)
                if [ ${#parts[@]} -eq 0 ]; then
                    log_warn "至少需要创建一个分区"
                    continue
                else
                    break
                fi
                ;;
            *)
                local size_mib=0
                if [[ "$size_input" =~ ^[0-9]+[MmGg]?$ ]]; then
                    size_mib=$(numfmt --from=iec "${size_input}" 2>/dev/null | awk '{print int($1/1024/1024)}')
                elif [[ "$size_input" == "remain" ]]; then
                    size_mib=$remain_mib
                else
                    log_warn "格式错误，使用 500M, 10G 或 remain"
                    continue
                fi

                if [ -z "$size_mib" ] || [ $size_mib -le 0 ]; then
                    log_warn "大小无效"
                    continue
                fi
                if [ $size_mib -gt $remain_mib ]; then
                    log_warn "剩余空间不足（剩余 ${remain_mib} MiB）"
                    continue
                fi

                read -p "挂载点绝对路径（如 /mnt/data）: " mnt
                while [[ ! "$mnt" =~ ^/ ]]; do
                    log_warn "挂载点必须以 / 开头"
                    read -p "挂载点: " mnt
                done

                parts+=("$size_mib:$mnt")
                used_mib=$((used_mib + size_mib))
                log_info "已添加分区 $part_num：大小 ${size_mib} MiB，挂载点 $mnt"
                ((part_num++))
                ;;
        esac
    done

    if [ ${#parts[@]} -eq 0 ]; then
        log_warn "未添加任何分区，跳过"
        return 1
    fi

    echo -e "\n${BLUE}======== 最终分区方案 ========${NC}"
    for i in "${!parts[@]}"; do
        local size=$(echo "${parts[$i]}" | cut -d: -f1)
        local mnt=$(echo "${parts[$i]}" | cut -d: -f2)
        echo "分区 $((i+1)): 大小 ${size} MiB, ext4, 挂载点 $mnt"
    done
    echo "================================"
    read -p "确认执行分区? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "取消分区操作"
        return 1
    fi

    log_info "正在创建分区表及分区..."
    local sfdisk_cmds="label: gpt\nunit: MiB\n"
    local start_mib=1
    local part_count=${#parts[@]}
    local part_index=1
    for part in "${parts[@]}"; do
        local size_mib=$(echo "$part" | cut -d: -f1)
        if [ $part_index -eq $part_count ]; then
            sfdisk_cmds+="start=${start_mib}, size= , type=Linux\n"
        else
            sfdisk_cmds+="start=${start_mib}, size=${size_mib}MiB, type=Linux\n"
        fi
        start_mib=$((start_mib + size_mib))
        ((part_index++))
    done

    echo -e "$sfdisk_cmds" | sfdisk "$disk" >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        log_error "sfdisk 执行失败，请检查分区参数"
        return 1
    fi
    udevadm settle
    partprobe "$disk" 2>/dev/null || true
    udevadm settle

    part_index=1
    start_mib=1
    for part in "${parts[@]}"; do
        local size_mib=$(echo "$part" | cut -d: -f1)
        local mnt=$(echo "$part" | cut -d: -f2)

        local part_dev
        if [[ "$disk" =~ nvme[0-9]+n[0-9]+$ ]]; then
            part_dev="${disk}p${part_index}"
        else
            part_dev="${disk}${part_index}"
        fi
        while [ ! -b "$part_dev" ]; do
            sleep 0.2
            udevadm settle
        done

        log_info "创建分区 $part_dev (起始 ${start_mib}MiB, 大小 ${size_mib}MiB)"
        mkfs.ext4 -F "$part_dev" >/dev/null
        log_info "格式化 $part_dev 为 ext4"

        mkdir -p "$mnt"
        local uuid=$(blkid -s UUID -o value "$part_dev")
        echo "# $mnt was on $part_dev" >> /etc/fstab
        echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
        log_info "已添加 $mnt 到 /etc/fstab"

        mount "$part_dev" "$mnt"
        log_info "已挂载 $part_dev 到 $mnt"

        start_mib=$((start_mib + size_mib))
        ((part_index++))
    done

    log_info "分区配置完成"
}

# 配置单块硬盘（格式化并挂载）
config_disk() {
    local disk="$1"
    local size_h="$2"

    log_info "===== 开始配置硬盘 $disk ($size_h) ====="
    umount_disk "$disk"
    if ! clear_partition_table "$disk"; then
        log_info "跳过此硬盘"
        return 1
    fi

    echo -e "\n${BLUE}请选择分区方式：${NC}"
    echo "  1) 整个硬盘分为一个分区（自动占满全部空间）"
    echo "  2) 交互式分区（支持多个分区，remain 占满剩余）"
    read -p "请选择 (1/2): " mode

    case "$mode" in
        1)
            read -p "请输入挂载点（如 /mnt/data）: " mnt
            while [[ ! "$mnt" =~ ^/ ]]; do
                log_warn "挂载点必须以 / 开头"
                read -p "挂载点: " mnt
            done
            create_single_partition "$disk" "$mnt"
            ;;
        2)
            interactive_partition "$disk"
            ;;
        *)
            log_warn "无效选择，跳过此硬盘"
            return 1
            ;;
    esac

    log_info "$disk 配置成功"
}

# 格式化磁盘并挂载主流程
format_and_mount() {
    check_deps
    backup_fstab

    local sys_disk=$(get_system_disk)
    log_info "系统盘为 $sys_disk"
    local disks=()
    mapfile -t disks < <(get_other_disks)

    while true; do
        echo -e "\n${GREEN}可用的数据盘：${NC}"
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

# ==================== 挂载已有分区功能（修复版，使用 lsblk -P） ====================
mount_existing_partitions() {
    check_deps
    backup_fstab

    local sys_disk=$(get_system_disk)
    log_info "系统盘为 $sys_disk"

    local parts=()
    local part_sizes=()
    local other_disks=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk" {print "/dev/"$1}')
    for disk in $other_disks; do
        [ "$disk" = "$sys_disk" ] && continue
        # 使用 -P 键值对输出，避免空字段导致 read 解析错位
        while IFS= read -r line; do
            # 格式如：NAME="sdb1" FSTYPE="ext4" MOUNTPOINT="" SIZE="10G"
            eval "$line"
            # 注意：变量名必须与 lsblk 输出完全一致（大写）
            if [ "$FSTYPE" = "ext4" ] && [ -z "$MOUNTPOINT" ]; then
                local part_dev="/dev/$NAME"
                parts+=("$part_dev")
                part_sizes+=("$SIZE")
            fi
        done < <(lsblk -P -o NAME,FSTYPE,MOUNTPOINT,SIZE "$disk" 2>/dev/null)
    done

    if [ ${#parts[@]} -eq 0 ]; then
        log_error "未找到任何可用的 ext4 分区（非系统盘、未挂载）"
        return 1
    fi

    echo -e "\n${GREEN}找到以下可挂载的 ext4 分区：${NC}"
    for i in "${!parts[@]}"; do
        echo "  $((i+1))) ${parts[$i]} 大小: ${part_sizes[$i]}"
    done
    echo "  q) 退出"

    while true; do
        read -p "请选择要挂载的分区序号（输入序号，或 q 退出）: " sel
        if [[ "$sel" =~ ^[Qq]$ ]]; then
            break
        fi
        if [[ ! "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt ${#parts[@]} ]; then
            log_warn "无效选择"
            continue
        fi
        local idx=$((sel-1))
        local part_dev="${parts[$idx]}"

        # 二次确认是否已被挂载
        local cur_mount=$(findmnt -n -o TARGET "$part_dev" 2>/dev/null)
        if [ -n "$cur_mount" ]; then
            log_warn "$part_dev 已经挂载到 $cur_mount，跳过"
            continue
        fi

        local uuid=$(blkid -s UUID -o value "$part_dev")
        if [ -z "$uuid" ]; then
            log_error "无法获取 $part_dev 的 UUID，跳过"
            continue
        fi

        if grep -q "^UUID=$uuid " /etc/fstab; then
            log_warn "$part_dev 已在 /etc/fstab 中存在条目，但未挂载。将尝试挂载"
        fi

        local default_mnt="/mnt/$(basename "$part_dev")"
        read -p "请输入挂载点绝对路径 [默认: $default_mnt]: " mnt
        if [ -z "$mnt" ]; then
            mnt="$default_mnt"
        fi
        while [[ ! "$mnt" =~ ^/ ]]; do
            log_warn "挂载点必须以 / 开头"
            read -p "挂载点: " mnt
        done

        mkdir -p "$mnt"
        if ! grep -q "^UUID=$uuid " /etc/fstab; then
            echo "# $mnt was on $part_dev" >> /etc/fstab
            echo "UUID=$uuid $mnt ext4 defaults 0 2" >> /etc/fstab
            log_info "已添加 $mnt 到 /etc/fstab"
        else
            log_warn "fstab 中已存在 $part_dev 条目，跳过写入"
        fi

        mount "$part_dev" "$mnt"
        log_info "成功挂载 $part_dev 到 $mnt"
    done
    log_info "挂载操作完成"
}

# ==================== 主菜单（独立运行时） ====================
show_self_menu() {
    while true; do
        echo
        echo "========== 磁盘分区与挂载工具 =========="
        echo "1. 挂载已有分区"
        echo "2. 格式化磁盘并挂载"
        echo "e. 退出"
        echo "========================================"
        echo -n "请选择: "
        read -r choice
        case "$choice" in
            1) mount_existing_partitions ;;
            2) format_and_mount ;;
            e|E) exit 0 ;;
            *) log_warn "无效选择" ;;
        esac
    done
}

# ==================== 入口 ====================
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -eq 0 ]; then
        show_self_menu
    else
        case "$1" in
            --mount-existing)
                mount_existing_partitions
                ;;
            --format)
                format_and_mount
                ;;
            *)
                echo "用法: $0 [--mount-existing|--format]"
                exit 1
                ;;
        esac
    fi
fi
