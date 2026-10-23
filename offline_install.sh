#!/bin/bash
# ============================================================
#  SaoML 8.15 全离线安装套件 - VPS 一键部署脚本
#  作用：把 xq688 域名的全部安装资源本地化，域名挂了照样装。
#  前提：本目录整体上传到 CentOS 7 x64 服务器，root 运行。
#  用法：bash offline_install.sh
#  之后直接运行: xsaoml  （或 bash cracked_stage5.sh，效果相同）
# ============================================================
KIT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$KIT_DIR" || exit 1

# 面板包以分卷形式随仓库分发，先还原
if [ ! -f file_8.15/web-8.15.zip ] && ls file_8.15/web-8.15.zip.part-* >/dev/null 2>&1; then
    echo "== [0/4] 合并面板包分卷 =="
    cat file_8.15/web-8.15.zip.part-* > file_8.15/web-8.15.zip || exit 1
    echo "  已还原: $(du -h file_8.15/web-8.15.zip | cut -f1)"
fi

echo "== [1/4] 资源自检 =="
MISS=0
check() { if [ -f "$1" ]; then echo "  OK   $1"; else echo "  缺失 $1"; MISS=1; fi; }
check oss_yum_public/unzip
check oss_yum_public/Killuser
check oss_yum_public/Centos-7.repo
check oss_yum_public/epel.repo
check oss_yum_public/epel-testing.repo
check oss_yum_public/SaoML_PHP.repo
check file_8.15/web-8.15.zip
check oss_yum_php_el7/repodata/repomd.xml
check oss_yum_php_el7/rpm_manifest.txt
check xsaoml
check httpserver
N=0; BAD=0
if [ -f oss_yum_php_el7/rpm_manifest.txt ]; then
  while read -r sz rel; do
    [ -z "$rel" ] && continue
    rel=${rel%%$'\r'}          # 容错：剥离可能的 CRLF 尾巴
    sz=${sz%%$'\r'}
    N=$((N+1))
    if [ ! -f "oss_yum_php_el7/$rel" ]; then echo "  缺失 oss_yum_php_el7/$rel"; BAD=$((BAD+1));
    elif [ "$(stat -c%s "oss_yum_php_el7/$rel" 2>/dev/null)" != "$sz" ]; then echo "  大小不符 oss_yum_php_el7/$rel"; BAD=$((BAD+1)); fi
  done < oss_yum_php_el7/rpm_manifest.txt
  if [ "$BAD" = "0" ]; then echo "  OK   php 仓库 $N/$N rpm（含 php70w 全系列 44 包，元数据中其余 346 个为作者服务器已删的死包，无需存在）"; else echo "  php 仓库损坏 $BAD 项"; MISS=1; fi
else
  echo "  缺失 oss_yum_php_el7/rpm_manifest.txt"; MISS=1
fi
if [ "$MISS" = "1" ]; then echo "!! 资源不完整，中止。请补齐后再运行。"; exit 1; fi

echo "== [2/4] hosts 劫持 oss.xq688.com.cn / file.xq688.com.cn -> 127.0.0.1 =="
for d in oss.xq688.com.cn file.xq688.com.cn; do
  if grep -qE "[[:space:]]$d([[:space:]]|$)" /etc/hosts; then
    echo "  已存在: $d"
  else
    echo "127.0.0.1 $d" >> /etc/hosts
    echo "  已追加: 127.0.0.1 $d"
  fi
done

echo "== [3/4] 启动本地资源服务器 (127.0.0.1:80) =="
if ss -tln 2>/dev/null | grep -q ':80 '; then
  echo "!! 80 端口被占用。安装器尚未装 nginx 前应无占用；请先释放 80 端口（通常是已有 web 服务），再重跑本脚本。"
  ss -tlnp | grep ':80 '
  exit 1
fi
chmod +x ./httpserver 2>/dev/null
pkill -f offline_http_server.py 2>/dev/null
pkill -f "offline_kit/httpserver" 2>/dev/null
if [ -x ./httpserver ]; then
  nohup ./httpserver 80 >/var/log/offline_http.log 2>&1 &
elif command -v python3 >/dev/null 2>&1; then
  nohup python3 "$KIT_DIR/offline_http_server.py" 80 >/var/log/offline_http.log 2>&1 &
else
  echo "!! 既无 httpserver 二进制也无 python3，无法启动资源服务器"; exit 1
fi
sleep 1
ok=0
for u in "http://oss.xq688.com.cn/yum/public/unzip" \
         "http://oss.xq688.com.cn/yum/php/el7/repodata/repomd.xml" \
         "http://file.xq688.com.cn/8.15/web-8.15.zip"; do
  code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 5 "$u")
  if [ "$code" = "200" ]; then echo "  OK   $u"; else echo "  FAIL($code) $u"; ok=1; fi
done
if [ "$ok" = "1" ]; then echo "!! 本地伺服自检失败，查看 /var/log/offline_http.log"; exit 1; fi

echo "== [4/4] 部署安装器 /bin/xsaoml =="
cp -f xsaoml /bin/xsaoml && chmod 777 /bin/xsaoml && echo "  OK   /bin/xsaoml 就绪"

echo
echo "=============================================="
echo " 离线环境就绪！作者域名已完全不需要。"
echo " 直接运行:  xsaoml"
echo " （或 bash cracked_stage5.sh，效果相同）"
echo " 安装完成后可关闭资源服务器:"
echo "   pkill -f offline_http_server.py"
echo "=============================================="
