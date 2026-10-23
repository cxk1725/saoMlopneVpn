#!/bin/bash
# ============================================================
#  宿主机环境检查（在 VPS 上运行，不是容器内）
#    bash docker/check-host.sh
#  逐项确认方案 A 的部署条件，给出结论。
# ============================================================
set -u

PASS=0
WARN=0
FAIL=0

ok()   { echo "  [OK]   $*"; PASS=$((PASS+1)); }
warn() { echo "  [警告] $*"; WARN=$((WARN+1)); }
err()  { echo "  [不满足] $*"; FAIL=$((FAIL+1)); }

echo "============================================================"
echo " SaoML 容器化 - 宿主机环境检查"
echo "============================================================"

echo
echo "== 1. cgroup 版本（决定 centos:7 的 systemd 能否运行）=="
if [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    err "cgroup v2（unified）。systemd 219 不支持 cgroup v2。"
    echo "         解决 A：内核参数加 systemd.unified_cgroup_hierarchy=0 后重启"
    echo "         解决 B：改用 cgroup v1 的发行版（CentOS 7/8、Ubuntu 20.04、Debian 11）"
else
    ok "cgroup v1"
fi

echo
echo "== 2. tun 设备（OpenVPN 必需）=="
if [ -c /dev/net/tun ]; then
    ok "/dev/net/tun 存在"
else
    modprobe tun 2>/dev/null
    if [ -c /dev/net/tun ]; then
        warn "/dev/net/tun 原缺失，已加载 tun 模块；请确保开机自动加载"
    else
        err "/dev/net/tun 缺失，且无法加载 tun 模块（多为 OpenVZ/LXC 容器机器）"
    fi
fi

echo
echo "== 3. 内核转发 =="
fwd=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo "?")
if [ "$fwd" = "1" ]; then
    ok "net.ipv4.ip_forward=1"
else
    warn "net.ipv4.ip_forward=$fwd（安装器会写入 sysctl.conf 并生效，需宿主持久化）"
fi

echo
echo "== 4. 端口占用（安装期 80 必须空闲）=="
if command -v ss >/dev/null 2>&1; then
    for p in 80 443 53 1024 1194 1195 1196 1197 8989; do
        if ss -tln 2>/dev/null | grep -q ":$p "; then
            if [ "$p" = "80" ]; then err "80/tcp 被占用（安装器需要）"; else warn "$p/tcp 已被占用"; fi
        fi
    done
    ss -uln 2>/dev/null | grep -q ':53 ' && warn "53/udp 被占用（dnsmasq 需要）" || true
else
    warn "缺少 ss 命令，跳过端口检查"
fi
[ "$FAIL" -eq 0 ] && ok "80 端口空闲"

echo
echo "== 5. iptables 后端（容器内是 EL7 的 legacy 版本）=="
if command -v iptables >/dev/null 2>&1; then
    ver=$(iptables --version 2>/dev/null)
    echo "         $ver"
    case "$ver" in
        *legacy*) ok "宿主使用 iptables-legacy，与容器内一致" ;;
        *nf_tables*) warn "宿主使用 nftables 后端；容器内规则仍走 legacy，两套规则会并存，建议宿主统一切到 iptables-legacy" ;;
        *) warn "无法识别 iptables 后端" ;;
    esac
else
    warn "宿主未安装 iptables（容器内自带，不影响，但建议宿主也装便于排查）"
fi

echo
echo "== 6. Docker =="
if command -v docker >/dev/null 2>&1; then
    dv=$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo "?")
    ok "Docker Server $dv"
    if docker compose version >/dev/null 2>&1; then
        cv=$(docker compose version --short 2>/dev/null || echo "?")
        ok "Docker Compose $cv"
    elif command -v docker-compose >/dev/null 2>&1; then
        warn "使用的是 docker-compose (v1)，不支持 cgroup: host 字段，请按 README 用 docker run 启动"
    else
        err "未找到 Compose"
    fi
else
    err "未安装 Docker"
fi

echo
echo "== 7. 磁盘空间（镜像 + 数据建议 >= 15G）=="
avail=$(df -h /var/lib/docker 2>/dev/null | awk 'NR==2{print $4}' || df -h / | awk 'NR==2{print $4}')
echo "         可用：${avail:-未知}"

echo
echo "============================================================"
echo " 结果：满足 $PASS 项 / 警告 $WARN 项 / 不满足 $FAIL 项"
if [ "$FAIL" -gt 0 ]; then
    echo " 结论：暂不满足部署条件，请先处理标注为 [不满足] 的项。"
else
    echo " 结论：可以部署。若只有警告项，按提示权衡后继续。"
fi
echo "============================================================"
