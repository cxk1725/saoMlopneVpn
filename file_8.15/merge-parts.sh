#!/bin/bash
# ============================================================
#  合并面板包分卷
#
#  web-8.15.zip（48 MB）在仓库里以 10 个 5 MB 分卷存放，
#  因为单文件整体推送在某些网络下会超时。
#  本脚本把 web-8.15.zip.part-* 还原成 web-8.15.zip。
#
#  正常部署时无需手动执行——offline_install.sh 和 Dockerfile
#  都会自动检测并合并。
# ============================================================
set -e
cd "$(dirname "$0")"

if [ -f web-8.15.zip ]; then
    echo "web-8.15.zip 已存在（$(du -h web-8.15.zip | cut -f1)），跳过"
    exit 0
fi

if ! ls web-8.15.zip.part-* >/dev/null 2>&1; then
    echo "找不到分卷 web-8.15.zip.part-*，无法合并" >&2
    exit 1
fi

echo "合并分卷..."
cat web-8.15.zip.part-* > web-8.15.zip
echo "完成: $(du -h web-8.15.zip | cut -f1)"
echo "sha256: $(sha256sum web-8.15.zip | cut -d' ' -f1)"
echo
echo "期望值（用于校验）:"
echo "fbedeaed9a866a011c4b6d29f0a7994e312c4d0a01aa8fbade0200117b419bec"
