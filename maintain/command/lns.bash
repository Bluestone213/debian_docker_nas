#!/bin/bash
# 自动创建维护所需的软连接（开机时由 crontab 调用）
ADMIN_HOME="/home/Adminli"

links=(
    "/mnt/database:docker_db"
    "/mnt/data:data"
    "/mnt/data/Manage/.syncthing:syncthing"
    "/mnt/database/bash/maintain:maintain"
    "/mnt/database/bash:bash"
)

for item in "${links[@]}"; do
    target="${item%%:*}"
    link_name="${item##*:}"
    link_path="$ADMIN_HOME/$link_name"
    ln -sfn "$target" "$link_path"
    echo "已创建/更新: $link_path -> $target"
done
