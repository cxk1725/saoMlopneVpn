#!/bin/bash
# ============================================================
#  SaoML APK 构建（加固版）
#
#  用法：
#    build-apk.sh <输出文件名> <ip> <port> <应用名> <包名> [app_key]
#
#  与面板自带的 shell/appgf、shell/appdl 参数兼容，但修掉了
#  原脚本的三个致命问题：
#    1) 先 rm 下载站的包再 cp 新包 —— 中途失败就永久失去安装包
#    2) 不检查 apktool/signapk 的返回码 —— 失败也报"编译成功"
#       （这正是用户下载到未注入地址模板包的直接原因）
#    3) sed 替换不转义 —— 应用名含 / & | 时会破坏 XML
#
#  现在的行为：
#    - 全程在临时文件里做，全部校验通过才原子替换
#    - 校验 APK 里不再有 IP:PORT 占位符、且包含真实 IP
#    - 任何一步失败都保留原有的包，并写日志 /var/log/saoml-apk.log
# ============================================================
set -uo pipefail

OUT_NAME="${1:-saoml.apk}"
IP="${2:-}"
PORT="${3:-}"
APPNAME="${4:-SaoML加速器}"
PKG="${5:-net.saoml.m}"
APPKEY="${6:-}"

DEST="/var/www/html/$OUT_NAME"
TMPDEST="/var/www/html/.${OUT_NAME}.tmp"
WORK=/tmp/APP
LOG=/tmp/saoml-apk.log
TPL_DIR=/var/www/html/shell/APP

touch "$LOG" 2>/dev/null; chmod 666 "$LOG" 2>/dev/null || true
log() { echo "[$(date '+%F %T')] $*" >> "$LOG" 2>/dev/null || true; }

fail() {
    echo "[失败] $*"
    log "FAIL($OUT_NAME): $*"
    rm -f "$TMPDEST" 2>/dev/null
    rm -rf "$WORK"/* 2>/dev/null
    exit 1
}

[ -n "$IP" ]   || fail "缺少 IP 参数"
[ -n "$PORT" ] || fail "缺少端口参数"
[ -f "$TPL_DIR/apktool.jar" ] || fail "缺少 apktool.jar"
[ -f "$TPL_DIR/saoml.apk" ]   || fail "缺少模板 saoml.apk"

log "===== 开始构建 $OUT_NAME ip=$IP port=$PORT name=$APPNAME pkg=$PKG key=${APPKEY:-<默认>} ====="

rm -rf "$WORK"/* "$WORK"/.[!.]* 2>/dev/null
mkdir -p "$WORK"
cd "$WORK" || fail "无法进入 $WORK"
cp -ri "$TPL_DIR"/. "$WORK"/ || fail "复制模板失败"
chmod -R 777 "$WORK"

echo "正在制作软件....."

java -jar apktool.jar empty-framework-dir >/dev/null 2>&1
java -jar apktool.jar d -f saoml.apk -o saoml >>"$LOG" 2>&1 || fail "apktool 解包失败（详见 $LOG）"
[ -f saoml/res/values/strings.xml ]  || fail "解包后缺少 strings.xml"
[ -f saoml/AndroidManifest.xml ]     || fail "解包后缺少 AndroidManifest.xml"

# 用 python 做替换：sed 遇到 / & | 会破坏 XML，应用名是用户自由输入的。
# 关键：写进 XML 前必须做实体转义，否则 "SaoML&测试版" 里的 & 会让
# 整个 strings.xml 变成非法 XML，apktool 打包直接失败（原脚本正是
# 在这种情况下静默失败，还照报"编译成功"）。
python - "$IP" "$PORT" "$APPNAME" "$PKG" "$APPKEY" <<'PYEOF' || fail "替换字符串失败"
# -*- coding: utf-8 -*-
import io, sys
ip, port, name, pkg, key = [a.decode('utf-8') for a in sys.argv[1:6]]

def xesc(t):
    return (t.replace(u'&', u'&amp;')
             .replace(u'<', u'&lt;')
             .replace(u'>', u'&gt;')
             .replace(u'"', u'&quot;'))

p = 'saoml/res/values/strings.xml'
s = io.open(p, encoding='utf-8').read()
s = s.replace(u'http://IP:PORT', u'http://%s:%s' % (ip, port))
s = s.replace(u'>软件名称<', u'>%s<' % xesc(name))
if key:
    s = s.replace(u'dailikey', xesc(key))
io.open(p, 'w', encoding='utf-8').write(s)

m = 'saoml/AndroidManifest.xml'
s = io.open(m, encoding='utf-8').read()
s = s.replace(u'net.saoml.m', pkg)
io.open(m, 'w', encoding='utf-8').write(s)
PYEOF

echo "正在编译软件....."

# 必须清掉 apktool 的增量缓存：build/ 里存着上一次编译的 resources.arsc，
# 不清的话新改的 strings.xml 不会进包（表现为"打包成功但地址没注入"）
rm -rf saoml/build saoml/dist
java -jar apktool.jar b saoml -o "$WORK/out.apk" >>"$LOG" 2>&1 || fail "apktool 打包失败（详见 $LOG）"
[ -s "$WORK/out.apk" ] || fail "打包产物不存在"

unzip -o signer.zip >/dev/null 2>&1 || fail "解压签名工具失败"
java -jar signapk.jar testkey.x509.pem testkey.pk8 \
     "$WORK/out.apk" "$TMPDEST" >/dev/null 2>&1 || fail "签名失败"
[ -s "$TMPDEST" ] || fail "签名产物为空"

# ---- 注入结果校验：这一步是防"坏包上线"的最后闸门 ----
# 注意：不能写成 `unzip -p ... | grep -q`——grep -q 命中即退出会让 unzip
# 收到 SIGPIPE 返回 141，配合 pipefail 会把"成功"误判成失败。
unzip -p "$TMPDEST" resources.arsc > "$WORK/.check.arsc" 2>/dev/null
if [ ! -s "$WORK/.check.arsc" ]; then
    fail "校验不通过：无法读取 APK 的 resources.arsc"
fi
if grep -aq 'IP:PORT' "$WORK/.check.arsc"; then
    fail "校验不通过：APK 内仍残留 IP:PORT 占位符，已保留原包"
fi
if ! grep -aq "$IP" "$WORK/.check.arsc"; then
    fail "校验不通过：APK 内未找到 $IP，已保留原包"
fi
rm -f "$WORK/.check.arsc"

chmod 644 "$TMPDEST"
# 同分区 mv 是原子操作：要么是旧包，要么是新包，不会出现半成品
mv -f "$TMPDEST" "$DEST" || fail "替换 $DEST 失败"
# 自愈脚本以 root 运行，产物必须交回 apache，否则面板（apache 身份）改不动
chown apache:apache "$DEST" 2>/dev/null || true
chmod 644 "$DEST" 2>/dev/null || true

log "OK($OUT_NAME): $(stat -c%s "$DEST") bytes"
rm -rf "$WORK"/* 2>/dev/null
echo "软件编译成功....."
exit 0
