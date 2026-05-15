#!/bin/bash
# 脚本：install_docker.sh
# 功能：安装 Docker（中国大陆优化），从 $config_dir/docker_daemon.json.bak 生成 daemon.json，
#       添加 "iptables": false 配置，并将 Nas_Admin 加入 docker 组
# 用法：./install_docker.sh --config.json
# 注意：如果 Docker 已安装，则跳过安装步骤，但会更新 daemon.json 并重启 Docker

set -e

# 帮助信息
if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    cat << EOF
用法: $0 --配置文件.json

从 ${config_dir:-当前目录下的config子目录}/docker_daemon.json.bak 复制到 /etc/docker/daemon.json，
并添加 "iptables": false 配置，然后设置权限 644、所有者 root:root。
然后检测 Docker 是否已安装：
  - 若未安装，则安装 Docker CE（使用清华镜像源）
  - 若已安装，则跳过安装步骤
并从指定的配置文件中读取 "Nas_Admin" 用户名，将其添加到 docker 组。

示例: $0 --config.json
EOF
    exit 0
fi

# 参数检查
if [ $# -ne 1 ]; then
    echo "错误: 必须指定配置文件 (--文件名.json)"
    exit 1
fi

case "$1" in
    --*)
        INPUT_FILE="${1#--}"
        ;;
    *)
        echo "错误: 参数必须以 -- 开头，例如 --config.json"
        exit 1
        ;;
esac

if [ ! -f "$INPUT_FILE" ]; then
    echo "错误: 找不到文件 $INPUT_FILE"
    exit 1
fi

# 检查 config_dir 环境变量
if [ -z "$config_dir" ]; then
    echo "错误: 环境变量 config_dir 未设置，请确保从主脚本调用此脚本。"
    exit 1
fi

# 源文件路径
SOURCE_DAEMON="${config_dir}/docker_daemon.json.bak"
if [ ! -f "$SOURCE_DAEMON" ]; then
    echo "错误: 找不到 Docker daemon 配置文件 $SOURCE_DAEMON"
    exit 1
fi

# 1. 安装 jq（如果未安装）用于 JSON 处理
if ! command -v jq &> /dev/null; then
    echo ">>> 安装 jq (JSON 处理工具)..."
    apt update && apt install -y jq
fi

# 2. 生成最终的 daemon.json，确保包含 "iptables": false
mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ]; then
    cp /etc/docker/daemon.json /etc/docker/daemon.json.bak.$(date +%Y%m%d_%H%M%S)
    echo "已备份原 /etc/docker/daemon.json"
fi

# 读取源文件内容，若为空则初始化为空对象
if [ -s "$SOURCE_DAEMON" ]; then
    # 使用 jq 合并：先读取源文件内容，再添加 iptables: false，如果已有则覆盖
    jq '. + {"iptables": false}' "$SOURCE_DAEMON" > /etc/docker/daemon.json
else
    # 源文件为空，直接创建包含 iptables: false 的配置
    echo '{"iptables": false}' > /etc/docker/daemon.json
fi

chmod 644 /etc/docker/daemon.json
chown root:root /etc/docker/daemon.json
echo "已生成 /etc/docker/daemon.json，并强制添加了 \"iptables\": false"
echo "当前 daemon.json 内容："
cat /etc/docker/daemon.json

# 3. 检测 Docker 是否已安装
if command -v docker &> /dev/null; then
    echo "Docker 已安装，版本: $(docker --version)"
    echo "跳过安装步骤，但将重启 Docker 以应用新配置..."
    systemctl restart docker
else
    echo "Docker 未安装，开始安装..."

    # 安装依赖
    echo ">>> 安装 Docker 依赖..."
    apt update
    apt install -y ca-certificates curl gnupg lsb-release

    # 添加 Docker 清华 APT 仓库
    echo ">>> 添加 Docker 清华 APT 仓库..."
    rm -f /usr/share/keyrings/docker-archive-keyring.gpg
    curl -fsSL https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

    # 安装 Docker CE 及插件
    echo ">>> 安装 Docker CE 及插件..."
    apt update
    apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

    systemctl enable docker
    systemctl restart docker
    echo "Docker 安装完成，版本: $(docker --version)"
fi

# 4. 从整个 JSON 文件中提取 Nas_Admin 用户
NAS_ADMIN=""
NAS_ADMIN_LINE=$(grep -E '["“]Nas_Admin["”][[:space:]]*:' "$INPUT_FILE" | head -1)
if [ -n "$NAS_ADMIN_LINE" ]; then
    NAS_ADMIN=$(echo "$NAS_ADMIN_LINE" | sed -E 's/.*:[[:space:]]*["“]?([^"“”]+)["“”]?.*/\1/' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
fi

if [ -z "$NAS_ADMIN" ]; then
    echo "警告: 配置文件中未找到 Nas_Admin 用户，跳过添加 docker 组"
else
    if id "$NAS_ADMIN" &>/dev/null; then
        usermod -aG docker "$NAS_ADMIN"
        echo "已将用户 $NAS_ADMIN 添加到 docker 组（重新登录生效）"
    else
        echo "警告: 用户 $NAS_ADMIN 不存在，无法添加到 docker 组"
    fi
fi

# 5. 测试 Docker
echo ">>> 测试 Docker 运行..."
if docker run --rm hello-world > /dev/null 2>&1; then
    echo "Docker 测试成功！"
else
    echo "警告: Docker 测试失败，请手动检查"
fi

# 6. 提示 iptables 已禁用
echo "=========================================="
echo "已禁用 Docker 自动添加 iptables 规则。"
echo "所有 Docker 容器的端口将不再自动暴露。"
echo "请使用 ufw 统一管理端口开放。"
echo "=========================================="

echo "完成。"
