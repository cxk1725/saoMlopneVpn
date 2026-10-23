#!/bin/bash
# ============================================================
#  SaoML 运行环境恢复（在新服务器上执行）
#
#  用法：
#    bash restore.sh                          # 当前目录就是备份目录
#    bash restore.sh /root/saoml-backup-xxx   # 指定备份目录
#    bash restore.sh /root/saoml-backup-xxx.tar   # 直接给 tar，自动解包
#    bash restore.sh <路径> --force           # 数据卷已存在时强制覆盖
#
#  做的事：
#    1. 环境检查（Docker / cgroup v1 / tun / 端口）
#    2. docker load 导入 saoml:8.15-installed
#    3. 创建 docker_saoml_* 卷并解回数据
#    4. 用备份包里的 compose 启动
# ============================================================
set -euo pipefail

IMAGE="${IMAGE:-saoml:8.15-installed}"
PROJECT="${PROJECT:-docker}"
VOLS="mysql openvpn www state log"
FORCE=0
SRC=""

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=1 ;;
        -*)      echo "未知参数: $arg"; exit 1 ;;
        *)       SRC="$arg" ;;
    esac
done

log()  { echo "[restore] $*"; }
warn() { echo "[警告] $*"; }

# ---------- 定位备份目录 ----------
if [ -n "$SRC" ] && [ -f "$SRC" ] && [[ "$SRC" == *.tar ]]; then
    DEST=$(dirname "$SRC")
    NAME=$(basename "$SRC" .tar)
    log "解包 $(basename "$SRC") ..."
    tar xf "$SRC" -C "$DEST"
    PKG="$DEST/$NAME"
elif [ -n "$SRC" ] && [ -d "$SRC" ]; then
    PKG=$(cd "$SRC" && pwd)
else
    PKG=$(cd "$(dirname "$0")" && pwd)
fi

[ -f "$PKG/image.tar.gz" ] || {
    echo "找不到 $PKG/image.tar.gz，请确认路径指向备份目录"
    exit 1
}

# ---------- 1. 环境检查 ----------
command -v docker >/dev/null 2>&1 || { echo "未安装 Docker"; exit 1; }
docker info >/dev/null 2>&1 || { echo "Docker 未运行"; exit 1; }

if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    warn "当前系统是 cgroup v2。centos:7 的 systemd 219 需要 cgroup v1，"
    warn "容器可能起不来。可用以下方式临时切回 v1（需重启）："
    warn "  grubby --update-kernel=ALL --args=\"systemd.unified_cgroup_hierarchy=0\""
fi

[ -e /dev/net/tun ] || warn "/dev/net/tun 不存在，VPN 无法工作（需在宿主机加载 tun 模块）"

for p in 80 1024 1194; do
    if (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ":$p "; then
        warn "端口 $p 已被占用，容器启动后可能冲突"
    fi
done

# ---------- 2. 导入镜像 ----------
if docker image inspect "$IMAGE" >/dev/null 2>&1; then
    log "镜像 $IMAGE 已存在，跳过导入"
else
    log "导入镜像（约 1.7 GB，需要几分钟）..."
    gzip -dc "$PKG/image.tar.gz" | docker load
fi

docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "镜像导入失败"; exit 1; }

# ---------- 3. 恢复数据卷 ----------
for v in $VOLS; do
    f="$PKG/vol-$v.tar.gz"
    [ -f "$f" ] || { log "跳过 vol-$v（备份中没有）"; continue; }
    full="${PROJECT}_saoml_$v"

    if docker volume inspect "$full" >/dev/null 2>&1; then
        if [ "$FORCE" = "1" ]; then
            warn "卷 $full 已存在，--force 覆盖（旧数据不会删除，只覆盖同名文件）"
        else
            warn "卷 $full 已存在，跳过。要覆盖请加 --force"
            continue
        fi
    else
        docker volume create "$full" >/dev/null
    fi

    log "恢复 $full ..."
    docker run --rm -v "$full":/data -v "$PKG":/backup "$IMAGE" \
        tar xzf "/backup/vol-$v.tar.gz" -C /data
done

# ---------- 4. 启动 ----------
COMPOSE_DIR=""
if [ -f "$PKG/docker/docker-compose.yml" ]; then
    COMPOSE_DIR="$PKG/docker"
elif [ -f "$PKG/docker-compose.yml" ]; then
    COMPOSE_DIR="$PKG"
fi

if [ -n "$COMPOSE_DIR" ]; then
    # 保险：compose 若仍写着基础镜像名，恢复后会启动一个空系统（数据卷有数据但系统层缺失）
    if grep -qE '^ *image: saoml:8\.15$' "$COMPOSE_DIR/docker-compose.yml"; then
        warn "compose 指向基础镜像 saoml:8.15，自动改为 $IMAGE（否则会起来一个空系统）"
        sed -i "s|^\( *\)image: saoml:8\.15$|\1image: $IMAGE|" "$COMPOSE_DIR/docker-compose.yml"
    fi
    log "启动容器（$COMPOSE_DIR）..."
    ( cd "$COMPOSE_DIR" && docker compose up -d --no-build )
    sleep 15
    echo
    log "容器状态："
    docker ps --format "  {{.Names}}  {{.Status}}  {{.Image}}" | grep -i saoml || true
    echo
    log "服务检查："
    docker exec saoml systemctl is-active mariadb httpd saoml 2>/dev/null | paste -sd' ' || true
else
    warn "备份包里没有 docker-compose.yml，需手动启动"
fi

cat <<'EOF'

==============================================================
  恢复完成。

  验证：
    curl -I http://127.0.0.1:1024/
    docker exec saoml systemctl --no-pager --type=service --state=running | head

  注意：管理员后台路径与密码沿用原服务器，未改变。
==============================================================
EOF
