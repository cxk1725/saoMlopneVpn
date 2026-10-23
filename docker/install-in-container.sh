#!/bin/bash
# ============================================================
#  容器内安装引导（在宿主机执行 docker exec 进入后运行）
#
#    docker exec -it saoml bash /opt/offline_kit/docker/install-in-container.sh
#
#  实测关键点（2026-10 真机验证）：
#    安装器用 `who | wc -l` 判断「是否多开 SSH 窗口」，
#    docker exec 不产生登录会话（who=0）会被直接判定为多开并退出。
#    因此本脚本改用容器内 sshd(2222) 建立**真实登录会话**，
#    再在会话里用 expect 自动应答。
# ============================================================
set -u

KIT=/opt/offline_kit
MARKER=/etc/saoml-installed
LOG=/var/log/saoml-install.log
SSH_PORT=2222

if [ -f "$MARKER" ]; then
    echo "本容器已安装（$MARKER 存在），无需重复执行。"
    echo "如需重装：docker compose down -v 后重新创建。"
    exit 0
fi

echo "== [1/4] 检查 systemd =="
if ! systemctl list-units >/dev/null 2>&1; then
    echo "!! systemd 不可用。确认：1) --privileged  2) 宿主为 cgroup v1"
    exit 1
fi
echo "   OK ($(systemctl is-system-running 2>/dev/null || echo unknown))"

echo "== [2/4] 检查本地资源伺服器 =="
bad=0
for u in "http://oss.xq688.com.cn/yum/public/unzip" \
         "http://oss.xq688.com.cn/yum/php/el7/repodata/repomd.xml" \
         "http://file.xq688.com.cn/8.15/web-8.15.zip"; do
    code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 6 "$u")
    echo "   $code  $u"
    [ "$code" = "200" ] || bad=1
done
if [ "$bad" = "1" ]; then
    echo "!! 资源伺服器异常，查看 /var/log/offline_http.log"
    exit 1
fi

echo "== [3/4] 准备真实 SSH 会话 =="
systemctl start sshd 2>/dev/null || true
if ! systemctl is-active sshd >/dev/null 2>&1; then
    echo "!! sshd 未运行，安装器会误判「多开SSH窗口」"
    exit 1
fi
mkdir -p /root/.ssh && chmod 700 /root/.ssh
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -t rsa -b 2048 -N "" -f /root/.ssh/id_rsa -q
fi
if ! grep -qF -f /root/.ssh/id_rsa.pub /root/.ssh/authorized_keys 2>/dev/null; then
    cat /root/.ssh/id_rsa.pub >> /root/.ssh/authorized_keys
fi
chmod 600 /root/.ssh/authorized_keys
echo "   OK (sshd :$SSH_PORT)"

echo "== [4/4] 安装 =="
cat <<'GUIDE'

安装器是交互式的，下面的 expect 脚本会自动应答：

  YUM 源       -> 1（阿里源）
  卡密验证     -> ml.saoml.com.cn（安装器内置的本地验证）
  安装模式     -> 1（全新安装）
  后台地址     -> 回车（随机 5 位）
  数据库密码   -> 见下（可用 SAOML_DB_PASS 覆盖）
  APP 名称     -> 回车（默认 SaoML加速器）
  已阅读       -> 回车

安装共 8 步，约 10-30 分钟（取决于带宽）。

GUIDE
echo "   数据库密码：${SAOML_DB_PASS:-Saoml2026Test!x}"
echo

export SAOML_DB_PASS="${SAOML_DB_PASS:-Saoml2026Test!x}"
export SAOML_APP_NAME="${SAOML_APP_NAME:-}"

cd "$KIT" || exit 1
ssh -tt -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    root@127.0.0.1 "cd $KIT && expect -f $KIT/docker/auto-install.exp" 2>&1 | tee "$LOG"

echo
echo "------------------------------------------------------------"

if [ -f /var/www/html/config.php ]; then
    date > "$MARKER"

    # 安装加固版 APP 构建脚本（替换面板自带的脆弱版本）
    # 原生脚本的三个坑：根目录 mkdir /APP 无权限、失败也报"编译成功"、
    # 先删下载站的包再 cp（中途失败就永久失去安装包）。
    PANEL_SRC="$KIT/docker/panel"
    if [ -d "$PANEL_SRC" ]; then
        chmod +x "$PANEL_SRC"/*.sh "$PANEL_SRC/appgf" "$PANEL_SRC/appdl" 2>/dev/null
        cp -f "$PANEL_SRC/appgf" /var/www/html/shell/appgf 2>/dev/null
        cp -f "$PANEL_SRC/appdl" /var/www/html/shell/appdl 2>/dev/null
        chmod +x /var/www/html/shell/appgf /var/www/html/shell/appdl 2>/dev/null
    fi
    rm -rf /APP   # 面板若用 /APP 是否存在判断任务忙，残留会导致「任务较多」

    # 装完立即生成一次安装包，注入真实服务器地址。
    # 不生成的话，下载站上会是未注入地址的模板包（装上就"没网"）。
    DBPASS=$(sed -n 's/.*define("_pass_","\([^"]*\)".*/\1/p' /var/www/html/config.php 2>/dev/null | head -1)
    DBNAME=$(sed -n 's/.*define("_ov_","\([^"]*\)".*/\1/p' /var/www/html/config.php 2>/dev/null | head -1)
    DB=${DBNAME:-vpndata}

    # 真实公网地址在 web_fwq.ipport（安装器自己检测到的）；
    # map.host 在全新安装时是中文占位「流控地址」，直接注入会产出废包。
    FWQ=$(mysql -uroot -p"$DBPASS" "$DB" -N -e \
          "select ipport from web_fwq order by id limit 1" 2>/dev/null | head -1)
    APP_IP=${FWQ%%:*}
    APP_PORT=${FWQ##*:}

    if ! printf '%s' "$APP_IP" | LC_ALL=C grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$'; then
        HOST=$(mysql -uroot -p"$DBPASS" "$DB" -N -e \
               "select value from map where \`key\`='host'" 2>/dev/null | head -1)
        APP_IP=$(printf '%s' "$HOST" | sed -E 's#^https?://##; s#[:/].*$##')
        APP_PORT=$(printf '%s' "$HOST" | sed -nE 's#^[^:]+:([0-9]+).*#\1#p')
    fi
    APP_PORT=${APP_PORT:-1024}

    if [ -n "$APP_IP" ] && [ -f "$PANEL_SRC/build-apk.sh" ]; then
        echo "== 生成安装包（$APP_IP:${APP_PORT:-1024}）..."
        bash "$PANEL_SRC/build-apk.sh" saoml.apk "$APP_IP" "${APP_PORT:-1024}" \
             "SaoML加速器" "net.saoml.m" "" 2>&1 | tail -3
    else
        echo "!! 未能读取 host 配置，跳过 APK 生成（可稍后在后台生成）"
    fi

    [ -f /etc/sysconfig/iptables ] && cp -f /etc/sysconfig/iptables /var/lib/saoml/iptables.bak
    [ -d /root/res ] && tar czf /var/lib/saoml/res-backup.tar.gz -C /root res 2>/dev/null
    pkill -f "httpserver 80" 2>/dev/null || true
    pkill -f offline_http_server.py 2>/dev/null || true

    echo "== 安装成功"
    echo
    echo "== 管理员密码与后台地址："
    grep -aE "管理员密码|管理员地址|数据库密码" "$LOG" | tail -5
    echo
    echo "== 立刻固化系统层（宿主机执行）："
    echo "     docker commit saoml saoml:8.15-installed"
    echo "   然后把 docker-compose.yml 的 image 改为 saoml:8.15-installed"
    echo "== 然后：docker restart saoml"
else
    echo "!! 未检测到 /var/www/html/config.php，安装可能未完成"
    echo "   查看日志：tail -n 60 $LOG"
fi
