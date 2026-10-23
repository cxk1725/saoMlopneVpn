#!/bin/bash
# ============================================================
#  下载站 APK 自愈
#
#  场景：容器重建 / 数据卷被替换 / 面板生成失败，导致
#        /var/www/html/saoml.apk 退回成「未注入服务器地址」的模板包，
#        用户装上去就是"没网"。
#
#  做法：检测 resources.arsc 里是否还有 IP:PORT 占位符，
#        有就等 MySQL 就绪后，用数据库里配置的 host 重新构建。
#
#  该脚本由 entrypoint 在「已安装」分支后台拉起，不阻塞启动。
# ============================================================
set -uo pipefail

APK=/var/www/html/saoml.apk
CONF=/var/www/html/config.php
BUILD=/opt/offline_kit/docker/panel/build-apk.sh
LOG=/tmp/saoml-apk.log

log() { echo "[$(date '+%F %T')] [heal] $*" >> "$LOG" 2>/dev/null || true; }

[ -f "$APK" ] || exit 0
[ -x "$BUILD" ] || [ -f "$BUILD" ] || { log "缺少 build-apk.sh，跳过"; exit 0; }

# 有占位符才需要修
# 注意：不能写 `unzip -p ... | grep -q`，grep -q 提前退出会让 unzip 收到
# SIGPIPE 返回 141，配合 pipefail 会把"确实存在占位符"误判成不存在。
unzip -p "$APK" resources.arsc > /tmp/.heal.arsc 2>/dev/null
if ! grep -aq 'IP:PORT' /tmp/.heal.arsc 2>/dev/null; then
    rm -f /tmp/.heal.arsc
    exit 0
fi
rm -f /tmp/.heal.arsc

log "检测到未注入地址的模板包，准备重建"

DBPASS=$(sed -n 's/.*define("_pass_","\([^"]*\)".*/\1/p' "$CONF" 2>/dev/null | head -1)
DBNAME=$(sed -n 's/.*define("_ov_","\([^"]*\)".*/\1/p' "$CONF" 2>/dev/null | head -1)
DBNAME=${DBNAME:-vpndata}

# 等 MySQL 起来（最多 3 分钟）
for _ in $(seq 1 90); do
    mysql -uroot -p"$DBPASS" "$DBNAME" -N -e "select 1" >/dev/null 2>&1 && break
    sleep 2
done

HOST=$(mysql -uroot -p"$DBPASS" "$DBNAME" -N -e \
       "select value from map where \`key\`='host'" 2>/dev/null | head -1)

# 优先取 web_fwq.ipport：安装器检测到的真实公网地址。
# map.host 在全新安装时是中文占位「流控地址」，注进去等于没修。
FWQ=$(mysql -uroot -p"$DBPASS" "$DBNAME" -N -e \
      "select ipport from web_fwq order by id limit 1" 2>/dev/null | head -1)
IP=${FWQ%%:*}
PORT=${FWQ##*:}

if ! printf '%s' "$IP" | LC_ALL=C grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    IP=$(printf '%s' "$HOST" | sed -E 's#^https?://##; s#[:/].*$##')
    PORT=$(printf '%s' "$HOST" | sed -nE 's#^[^:]+:([0-9]+).*#\1#p')
fi
PORT=${PORT:-1024}

if ! printf '%s' "$IP" | LC_ALL=C grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
    log "找不到可用的公网 IP（web_fwq/map.host 均为空或占位符），跳过自愈"
    exit 1
fi

[ -n "$IP" ] || { log "host 解析失败: $HOST"; exit 1; }

log "使用 host=$HOST -> $IP:$PORT 重建"
bash "$BUILD" saoml.apk "$IP" "$PORT" "SaoML加速器" "net.saoml.m" ""
