# ============================================================
#  SaoML 8.15 离线套件 —— Docker 整机封装镜像（方案 A）
#
#  构建（在 offline_kit 根目录执行）：
#    docker build -f docker/Dockerfile -t saoml:8.15 .
#
#  说明：
#    基础镜像为 centos:7（7.9.2009 用户态），容器内会完整跑一遍
#    官方 xsaoml 安装器，产出一套「装好的 SaoML 系统」。
#    镜像本身不含已安装的 SaoML —— 安装发生在容器首次启动后，
#    原因是安装器依赖运行中的 systemd，且安装完成后需记录随机
#    生成的管理员密码。
# ============================================================
FROM centos:7

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    container=docker \
    KIT=/opt/offline_kit

# ------------------------------------------------------------
# 1. 修复 EOL yum 源
#    CentOS 7 已于 2024-06-30 EOL，官方 mirror.centos.org 下线。
#    经实测以下地址可用（2026-10）：
#      http://mirrors.aliyun.com/centos/7/
#      http://mirrors.aliyun.com/centos-vault/7.9.2009/
# ------------------------------------------------------------
RUN mkdir -p /etc/yum.repos.d/orig \
    && mv /etc/yum.repos.d/*.repo /etc/yum.repos.d/orig/ 2>/dev/null || true

RUN printf '%s\n' \
    '[base]' \
    'name=CentOS-7 - Base - aliyun' \
    'baseurl=http://mirrors.aliyun.com/centos/7/os/$basearch/' \
    'gpgcheck=0' \
    'enabled=1' \
    '' \
    '[updates]' \
    'name=CentOS-7 - Updates - aliyun' \
    'baseurl=http://mirrors.aliyun.com/centos/7/updates/$basearch/' \
    'gpgcheck=0' \
    'enabled=1' \
    '' \
    '[extras]' \
    'name=CentOS-7 - Extras - aliyun' \
    'baseurl=http://mirrors.aliyun.com/centos/7/extras/$basearch/' \
    'gpgcheck=0' \
    'enabled=1' \
    '' \
    '[epel]' \
    'name=EPEL-7 - aliyun' \
    'baseurl=https://mirrors.aliyun.com/epel/7/$basearch' \
    'gpgcheck=0' \
    'enabled=1' \
    > /etc/yum.repos.d/CentOS-Base.repo

# ------------------------------------------------------------
# 2. systemd + 基础工具
#    严禁预装 httpd / mariadb / php / mysql-client：
#    安装器检测到 /usr/bin/mysql 等残留会直接拒绝安装。
# ------------------------------------------------------------
RUN yum -y install \
        systemd systemd-sysv initscripts \
        curl wget unzip tar which \
        procps-ng net-tools lsof gawk dos2unix expect \
        iproute psmisc util-linux \
        e2fsprogs openssh-server \
    && yum clean all \
    && rm -rf /var/cache/yum /tmp/*

# ------------------------------------------------------------
# 3. 实测踩坑修复（必须，否则安装器会中途退出）
#    a) /bin/chattr 必须存在：centos:7 精简镜像删了 e2fsprogs 里的 chattr，
#       安装器检测不到会报「chattr异常」直接停止
#    b) SELinux 配置文件必须存在且为 disabled：容器内 setenforce 必然失败，
#       安装器把「setenforce 返回非 0」当作致命错误
#    c) 容器内 sshd：安装器用 `who | wc -l` 判断「多开SSH窗口」，
#       docker exec 没有真实登录会话（who=0）会被误判，
#       必须通过真实 SSH 会话运行安装
# ------------------------------------------------------------
RUN mkdir -p /etc/selinux \
    && printf 'SELINUX=disabled\nSELINUXTYPE=targeted\n' > /etc/selinux/config

RUN if [ -f /usr/sbin/setenforce ]; then mv -f /usr/sbin/setenforce /usr/sbin/setenforce.real; fi \
    && printf '#!/bin/sh\nexit 0\n' > /usr/sbin/setenforce \
    && chmod +x /usr/sbin/setenforce

RUN sed -i 's/^#Port 22/Port 2222/' /etc/ssh/sshd_config \
    && sed -i 's/^#PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config \
    && ssh-keygen -A \
    && systemctl enable sshd 2>/dev/null || true

# ------------------------------------------------------------
# 3. 离线套件（xsaoml / cracked_stage5.sh / 资源目录 / httpserver）
# ------------------------------------------------------------
COPY . /opt/offline_kit

RUN chmod +x /opt/offline_kit/httpserver \
             /opt/offline_kit/xsaoml \
             /opt/offline_kit/*.sh \
             /opt/offline_kit/*.py 2>/dev/null || true

# 面板「生成软件」的加固版脚本（entrypoint 每次启动会覆盖到 /var/www/html/shell/）
RUN chmod +x /opt/offline_kit/docker/panel/*.sh \
             /opt/offline_kit/docker/panel/appgf \
             /opt/offline_kit/docker/panel/appdl 2>/dev/null || true

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh \
             /opt/offline_kit/docker/install-in-container.sh 2>/dev/null || true

WORKDIR /opt/offline_kit

# 运行期数据（compose 中挂载为命名卷）
# 注意：/var/saoml 故意不做卷 —— 安装器会 rm -rf 它，挂载点会导致删除失败
VOLUME ["/var/lib/mysql", "/etc/openvpn", "/var/www", "/var/lib/saoml", "/var/log"]

EXPOSE 80 443 1024 1194 1195 1196 1197 8989
EXPOSE 53/udp

# systemd 容器的优雅停止信号
STOPSIGNAL SIGRTMIN+3

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/sbin/init"]
