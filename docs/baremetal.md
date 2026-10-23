# 裸机部署（CentOS 7 x64）

直接把 SaoML 装在一台 CentOS 7 服务器上，不经过 Docker。资源全部本地化，不依赖作者域名。

## 前提

| 项 | 要求 |
|---|---|
| 系统 | CentOS 7 x64（7.0–7.9 均可，安装器本身要求 7.x） |
| 内存 | ≥ 2 GB |
| 磁盘 | ≥ 15 GB |
| 权限 | root |
| 网络 | 能访问 `mirrors.aliyun.com`（装系统包用）、`mirrors.aliyun.com/epel` |
| 端口 | **80 必须空闲**（安装期本地伺服器要占） |

> 安装器会覆盖 `/etc/sysctl.conf`、关闭 SELinux、写 iptables 规则、装 `saoml.service`。
> **不要装在与现有业务共用的机器上。**

## 一、上传

把整个目录传到服务器（约 76 MB）：

```powershell
# Windows
scp -r C:\path\to\offline_kit root@服务器IP:/root/
```

```bash
# Linux / macOS
scp -r ./offline_kit root@服务器IP:/root/
```

服务器上确认：

```bash
cd /root/offline_kit && ls
# 应该看到 xsaoml / httpserver / cracked_stage5.sh / oss_yum_public / oss_yum_php_el7 / file_8.15
```

## 二、一键准备离线环境

```bash
cd /root/offline_kit
bash offline_install.sh
```

这个脚本做四件事：

1. **资源自检** —— 逐个检查 `unzip`、repo 配置、`web-8.15.zip`、49 个 php70w rpm（按 `rpm_manifest.txt` 校验大小），缺一个就中止
2. **hosts 劫持** —— 把 `oss.xq688.com.cn`、`file.xq688.com.cn` 指向 `127.0.0.1`
3. **启动本地资源服务器** —— `httpserver 80`，并自检三条资源路由都返回 200
4. **部署安装器** —— 拷贝 `xsaoml` 到 `/bin/xsaoml`

成功会看到：

```
==============================================
 离线环境就绪！作者域名已完全不需要。
 直接运行:  xsaoml
==============================================
```

如果卡在第 3 步，多半是 80 端口被占：

```bash
ss -tlnp | grep ':80 '
# 停掉占用者（例如已有的 nginx/httpd），再重跑
```

## 三、运行安装器

```bash
xsaoml
```

或等价：

```bash
bash cracked_stage5.sh
```

> 必须**只开一个 SSH 窗口**。安装器用 `who | wc -l` 判断会话数，多开会被判定
> "请不要多开SSH窗口运行"并退出。如果确实只有你一个连接却被拦，先清空 utmp：
> `> /var/run/utmp`

### 交互答案

| 步骤 | 输入 |
|---|---|
| 卡密验证 | `ml.saoml.com.cn` |
| 安装模式 | `1`（全新安装） |
| 管理员后台地址 | 直接回车（随机生成 5 位） |
| 数据库密码 | 自定义，**记下来** |
| APP 名称 | 直接回车（默认 SaoML加速器） |
| 开始安装 | 直接回车 |

随后是 8 个步骤：环境检查 → 防火墙/SELinux → 初始化 → 安装运行环境（最慢，约 10–20 分钟）→ 建库 → 导入数据 → 生成 APP → 完成。

装完会打印：

```
恭喜 ... 管理员密码: xxxxx  数据库密码: xxxxx
```

## 四、安装后

```bash
# 服务状态
systemctl status mariadb httpd saoml

# 端口（1024 面板 / 1194-1197 VPN / 53 dnsmasq / 8989 命令通道）
ss -tlnp | grep -E ':(1024|1194|1195|1196|1197|8989)'

# 面板
curl -I http://127.0.0.1:1024/
```

| 项目 | 地址 |
|---|---|
| 用户端 | `http://服务器IP:1024/` |
| 管理后台 | `http://服务器IP:1024/<装完打印的5位>/` |
| APP 下载 | `http://服务器IP:1024/saoml.apk` |

安全组 / 防火墙需放行：`1024`、`1194-1197`（TCP）、`443`、`53/udp`、`8989`。

## 五、生成 APP（修复后台按钮的坑）

面板自带的 `shell/appgf` 在 root 目录下 `mkdir /APP`，而 httpd 以 **apache** 身份运行，
必然失败；更糟的是它失败后仍报"编译成功"，把**未注入服务器地址的模板包**放上
下载站，用户装上就是"没网"。

本套件用加固版替换它（安装时自动覆盖）：

```bash
# 手工生成（参数：输出文件 公网IP 端口 应用名 包名 [代理key]）
bash /opt/offline_kit/docker/panel/build-apk.sh saoml.apk 你的IP 1024 "应用名称" net.saoml.m ""
```

> 裸机部署时没有 `/opt/offline_kit`，脚本在 `docker/panel/` 下，可拷出来用：
> ```bash
> cp /root/offline_kit/docker/panel/build-apk.sh /var/www/html/shell/
> bash /var/www/html/shell/build-apk.sh saoml.apk 你的IP 1024 "应用名称" net.saoml.m ""
> ```

生成后校验：

```bash
unzip -p /var/www/html/saoml.apk resources.arsc | strings | grep http://
# 期望： http://你的IP:1024
# 若显示 http://IP:PORT，说明注入失败，检查 /tmp/saoml-apk.log
```

## 六、卸载 / 重装

安装器不支持"卸载"。重装需要：

```bash
systemctl stop saoml httpd mariadb
yum remove -y httpd mariadb-server php70w* 2>/dev/null
rm -rf /var/www/html /var/lib/mysql /etc/openvpn /root/res /bin/clean /bin/clean2
rm -f /etc/yum.repos.d/SaoML_PHP.repo /etc/sysconfig/iptables
# 然后重跑 xsaoml
```

> 更省事的做法是直接重装系统，或者改用 Docker 方式——删容器重建即可，见
> [docker.md](docker.md)。

## 与其他服务共存

不建议。安装器会：

- 覆盖 `/etc/sysctl.conf`（改内核参数）
- 执行 `service iptables save` 落盘规则（做 NAT REDIRECT 到 53）
- 关闭 SELinux
- 占用 80 以外的 1024 / 443 / 1194-1197 / 8989 / 53udp

如果必须共存，先用 `iptables-save > /root/iptables.before` 备份现有规则，装完再合并。
