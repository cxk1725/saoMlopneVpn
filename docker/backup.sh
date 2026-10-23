#!/bin/bash
# ============================================================
#  SaoML 运行环境迁移导出（在「已部署好的」服务器上执行）
#
#  用法：
#    bash docker/backup.sh              # 输出到 /root/saoml-backup-<时间戳>/
#    bash docker/backup.sh /data/bak    # 指定输出目录
#    bash docker/backup.sh --live       # 不停止容器（不推荐，MySQL 可能不一致）
#
#  产物：
#    <输出目录>/image.tar.gz      已装好的系统镜像 saoml:8.15-installed
#    <输出目录>/vol-*.tar.gz      5 个数据卷
#    <输出目录>/docker/           部署文件（compose + 安装/恢复脚本）
#    <输出目录>/meta.txt          校验信息
#    <输出目录>/restore.sh        新机器上的恢复脚本
#    以及同级目录下的 saoml-backup-<时间戳>.tar
#
#  恢复：把 .tar 拷到新机器，解包后执行里面的 restore.sh
# ============================================================
set -euo pipefail

IMAGE="${IMAGE:-saoml:8.15-installed}"
CONTAINER="${CONTAINER:-saoml}"
PROJECT="${PROJECT:-docker}"
VOLS="mysql openvpn www state log"

LIVE=0
OUT=""
for arg in "$@"; do
    case "$arg" in
        --live) LIVE=1 ;;
        -*)     echo "未知参数: $arg"; exit 1 ;;
        *)      OUT="$arg" ;;
    esac
done

STAMP=$(date +%Y%m%d-%H%M)
[ -z "$OUT" ] && OUT="/root/saoml-backup-$STAMP"
OUT=$(mkdir -p "$OUT" && cd "$OUT" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)

log() { echo "[backup] $*"; }

# ---------- 前置检查 ----------
command -v docker >/dev/null 2>&1 || { echo "未安装 docker"; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
    echo "镜像 $IMAGE 不存在。可用的 saoml 镜像："
    docker images | grep -i saoml || true
    exit 1
}

RUNNING=0
if [ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)" = "true" ]; then
    RUNNING=1
fi

if [ "$RUNNING" = "1" ] && [ "$LIVE" = "0" ]; then
    log "停止容器 $CONTAINER（保证 MySQL 数据一致）..."
    docker stop "$CONTAINER" >/dev/null
    trap 'log "重新启动容器..."; docker start "$CONTAINER" >/dev/null || true' EXIT
fi

# ---------- 1. 镜像 ----------
log "导出镜像 $IMAGE（约 1.7 GB，需要几分钟）..."
docker save "$IMAGE" | gzip -1 > "$OUT/image.tar.gz"
log "镜像完成: $(du -h "$OUT/image.tar.gz" | cut -f1)"

# ---------- 2. 数据卷 ----------
# 用镜像自带的 tar 打包，避免额外拉取镜像
for v in $VOLS; do
    full="${PROJECT}_saoml_$v"
    if docker volume inspect "$full" >/dev/null 2>&1; then
        log "导出卷 $full ..."
        docker run --rm -v "$full":/data:ro -v "$OUT":/backup "$IMAGE" \
            tar czf "/backup/vol-$v.tar.gz" -C /data . 2>/dev/null || true
        if [ -f "$OUT/vol-$v.tar.gz" ]; then
            log "  -> $(du -h "$OUT/vol-$v.tar.gz" | cut -f1)"
        else
            log "  -> 卷为空或打包失败，跳过"
        fi
    else
        log "跳过不存在的卷 $full"
    fi
done

# ---------- 3. 部署文件 ----------
log "复制部署文件..."
rm -rf "$OUT/docker"
mkdir -p "$OUT/docker"
for f in Dockerfile docker-compose.yml entrypoint.sh install-in-container.sh \
         auto-install.exp check-host.sh backup.sh restore.sh README.md; do
    if [ -f "$HERE/$f" ]; then cp -a "$HERE/$f" "$OUT/docker/"; fi
done
if [ -f "$HERE/restore.sh" ]; then cp -a "$HERE/restore.sh" "$OUT/restore.sh"; fi

# 备份包里的 compose 必须指向「已安装」镜像。
# 源主机的 compose 可能还写着基础镜像名 saoml:8.15，
# 直接拿来恢复会启动一个空系统（数据卷在，但系统层没有）。
if [ -f "$OUT/docker/docker-compose.yml" ]; then
    sed -i "s|^\( *\)image: saoml:8\.15$|\1image: ${IMAGE}|" "$OUT/docker/docker-compose.yml"
    log "compose 镜像已固定为 $(grep -E '^ *image:' "$OUT/docker/docker-compose.yml" | head -1 | tr -d ' ')"
fi
chmod +x "$OUT/restore.sh" "$OUT"/docker/*.sh 2>/dev/null || true

# ---------- 4. 元信息 ----------
{
    echo "SaoML 容器迁移备份"
    echo "导出时间   : $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "源主机     : $(hostname) / $(hostname -I 2>/dev/null | awk '{print $1}')"
    echo "镜像       : $IMAGE"
    echo "镜像 ID    : $(docker image inspect -f '{{.Id}}' "$IMAGE" | cut -c1-19)"
    echo "镜像大小   : $(docker image inspect -f '{{.Size}}' "$IMAGE" | awk '{printf "%.2f GB", $1/1024/1024/1024}')"
    echo "项目名     : $PROJECT（卷名前缀 ${PROJECT}_saoml_）"
    echo "容器       : $CONTAINER（导出前状态: $([ "$RUNNING" = "1" ] && echo 运行中 || echo 已停止)）"
    echo
    echo "数据卷："
    for v in $VOLS; do
        full="${PROJECT}_saoml_$v"
        if [ -f "$OUT/vol-$v.tar.gz" ]; then
            echo "  $full  ->  vol-$v.tar.gz  $(du -h "$OUT/vol-$v.tar.gz" | cut -f1)"
        fi
    done
    echo
    echo "SHA256："
    ( cd "$OUT" && sha256sum image.tar.gz vol-*.tar.gz 2>/dev/null )
} > "$OUT/meta.txt"

# ---------- 5. 打成单文件 ----------
PARENT=$(dirname "$OUT")
BASE=$(basename "$OUT")
log "打包为单文件..."
tar cf "$PARENT/$BASE.tar" -C "$PARENT" "$BASE"
log "完成: $PARENT/$BASE.tar  ($(du -h "$PARENT/$BASE.tar" | cut -f1))"
echo
echo "=============================================================="
echo "  迁移包: $PARENT/$BASE.tar"
echo
echo "  拷到新机器后："
echo "    tar xf $BASE.tar && cd $BASE && bash restore.sh"
echo "=============================================================="
