#!/bin/bash
# ============================================================
#  SaoML 容器入口脚本（PID 1 引导，最后 exec systemd）
#  职责：
#    1. 修复目录属主、重建 hosts 劫持（容器每次启动都会重置 hosts）
#    2. 已安装 -> 恢复 iptables / res 备份，直接交棒 systemd
#    3. 未安装 -> 启动本地资源伺服器，打印安装指引
# ============================================================
set -u

# marker 必须放在非卷路径：docker commit 不会打包卷内容，
# 而 /var/lib/saoml 是卷，放在那里 commit 后会丢失
MARKER=/etc/saoml-installed
BACKUP_RES=/var/lib/saoml/res-backup.tar.gz
BACKUP_IPT=/var/lib/saoml/iptables.bak

log() { echo "[entrypoint] $*"; }

log "初始化容器..."

mkdir -p /var/lib/saoml /var/log /var/saoml

# 注意：不要创建 /APP —— 面板用「/APP 是否存在」判断是否有 APP 打包任务在跑，
# 残留该目录会让后台一直提示「任务提交失败,或当前任务较多」。
# 打包脚本已改为使用 /tmp/APP（apache 可写）。

# mariadb 数据目录属主（空卷首次挂载时是 root）
if [ -d /var/lib/mysql ]; then
    chown -R mysql:mysql /var/lib/mysql 2>/dev/null || true
fi

# hosts 劫持：把作者域名指到本地伺服器
# 注意：Docker 每次启动会重写 /etc/hosts，所以必须每次执行
for d in oss.xq688.com.cn file.xq688.com.cn; do
    if grep -qE "[[:space:]]$d([[:space:]]|$)" /etc/hosts; then
        :
    else
        echo "127.0.0.1 $d" >> /etc/hosts
        log "hosts 已追加: 127.0.0.1 $d"
    fi
done

# ---------------- 已安装：正常启动 ----------------
if [ -f "$MARKER" ]; then
    log "检测到安装标记，进入正常运行模式"

    # ---- 面板「生成软件」脚本：每次启动覆盖为加固版（幂等）----
    # 加固点：失败不覆盖旧包、注入结果校验、原子替换。
    # 原脚本 apktool/signapk 失败也报"编译成功"，会把未注入地址的
    # 模板包放到下载站，用户装上就是"没网"。
    if [ -d /var/www/html/shell ]; then
        for f in appgf appdl; do
            if [ -f "/opt/offline_kit/docker/panel/$f" ]; then
                cp -f "/opt/offline_kit/docker/panel/$f" "/var/www/html/shell/$f" 2>/dev/null \
                    && chmod +x "/var/www/html/shell/$f" 2>/dev/null
            fi
        done
        chmod +x /opt/offline_kit/docker/panel/*.sh 2>/dev/null || true
        log "APP 构建脚本已同步为加固版"
    fi

    # ---- 下载站 APK 自愈：包若仍是未注入地址的模板，后台重建 ----
    if [ -f /opt/offline_kit/docker/panel/heal-apk.sh ]; then
        nohup bash /opt/offline_kit/docker/panel/heal-apk.sh >/dev/null 2>&1 &
        log "APK 自愈检查已启动（后台）"
    fi

    # 恢复 iptables 规则（容器内的 /etc/sysconfig 不持久化）
    if [ -f "$BACKUP_IPT" ]; then
        cp -f "$BACKUP_IPT" /etc/sysconfig/iptables 2>/dev/null || true
        log "iptables 规则已恢复"
    fi

    # 恢复 /root/res（安装产物，含端口记录与 saoml.service）
    if [ -f "$BACKUP_RES" ] && [ ! -d /root/res ]; then
        tar xzf "$BACKUP_RES" -C /root/ 2>/dev/null || true
        log "/root/res 已从备份恢复"
    fi

    exec "$@"
fi

# ---------------- 未安装：准备安装环境 ----------------
log "首次启动，尚未安装 SaoML，准备资源伺服器"

if (ss -tln 2>/dev/null || netstat -tln 2>/dev/null) | grep -q ':80 '; then
    log "!! 80 端口已被占用，资源伺服器未启动（安装会失败）"
else
    cd /opt/offline_kit || exit 1
    chmod +x ./httpserver 2>/dev/null || true
    if [ -x ./httpserver ]; then
        nohup ./httpserver 80 >/var/log/offline_http.log 2>&1 &
        log "httpserver 已启动（127.0.0.1:80）"
    else
        nohup python3 ./offline_http_server.py 80 >/var/log/offline_http.log 2>&1 &
        log "python 伺服器已启动（127.0.0.1:80）"
    fi
    sleep 1
fi

cat <<'BANNER'

==============================================================
  SaoML 容器已启动（当前状态：尚未安装）

  在宿主机执行：

    docker exec -it saoml bash /opt/offline_kit/docker/install-in-container.sh

  该脚本会通过容器内 sshd(2222) 建立真实登录会话再跑安装器
  —— 安装器用 `who | wc -l` 检测会话，docker exec 没有登录
  会话会被误判为「多开SSH窗口」，必须走真实 SSH 会话。

  安装完成后执行：

    docker commit saoml saoml:8.15-installed
    docker restart saoml

==============================================================

BANNER

exec "$@"
