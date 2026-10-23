# SaoML 8.15 — Docker 整机封装部署手册（方案 A）

把原本必须裸装在 CentOS 7 上的 SaoML 流控系统，封装成一个特权容器。
**宿主机可以换成任意系统**（Ubuntu 22.04 / Alma 9 / Debian 11…），容器内部仍是一套完整的 EL7 用户态。

---

## 1. 目录结构

```
offline_kit/
├── docker/
│   ├── Dockerfile                # 基础镜像（centos:7 + systemd + 离线套件）
│   ├── docker-compose.yml        # 运行参数（特权 / host 网络 / tun / 卷）
│   ├── entrypoint.sh             # 容器入口：hosts 劫持 + 资源伺服器 + 交棒 systemd
│   ├── install-in-container.sh   # 容器内安装引导（交互式）
│   ├── auto-install.exp          # 安装器自动应答（expect）
│   ├── check-host.sh             # 宿主机环境自检
│   ├── backup.sh                 # 迁移导出：镜像 + 数据卷 → 单个 tar
│   ├── restore.sh                # 迁移恢复：新机器一条命令还原
│   ├── panel/                    # 面板「生成软件」加固版
│   │   ├── build-apk.sh          # 构建 APK（注入校验 + 失败不覆盖）
│   │   ├── heal-apk.sh           # 下载站坏包自愈
│   │   └── appgf / appdl         # 面板调用入口
│   └── README.md                 # 本文档
├── .dockerignore
├── xsaoml                        # 官方安装器
├── cracked_stage5.sh             # 免卡密入口脚本
├── httpserver                    # 本地资源伺服器（Go）
├── oss_yum_public/               # yum 源与工具
├── oss_yum_php_el7/              # php70w 仓库（49 rpm）
└── file_8.15/web-8.15.zip        # 面板包（密码 Xq566621+）
```

---

## 2. 前提条件

| 项目 | 要求 | 说明 |
|---|---|---|
| **cgroup** | **必须是 v1** | centos:7 的 systemd 219 不支持 cgroup v2。Ubuntu 22.04+/Debian 12 默认是 v2 |
| tun 设备 | 存在 `/dev/net/tun` | OpenVZ/LXC 类机器可能没有，无法运行 OpenVPN |
| 80 端口 | 安装期间空闲 | 本地资源伺服器要占用 |
| 磁盘 | ≥ 15 GB | 镜像约 2 GB，日志与数据库持续增长 |
| Docker | 20.10+，Compose v2.15+ | 低版本 Compose 不支持 `cgroup: host`，改用文末的 `docker run` |
| 网络 | 能访问阿里云 yum 源 | 安装器要装 httpd/mariadb/php70w 等系统包 |

**部署前先在宿主机执行自检：**

```bash
bash docker/check-host.sh
```

出现 `[不满足]` 就先处理，不要往下走。

> 如果宿主是 cgroup v2，二选一：
> 1. 内核参数追加 `systemd.unified_cgroup_hierarchy=0` 后重启（`/etc/default/grub` → `grub2-mkconfig`）；
> 2. 换一台 cgroup v1 的机器（CentOS 7/8、Ubuntu 20.04、Debian 11）。

---

## 3. 构建镜像

在 `offline_kit` **根目录**执行（构建上下文必须包含全部离线资源）：

```bash
docker build -f docker/Dockerfile -t saoml:8.15 .
```

镜像只做三件事：换源、装 systemd 与基础工具、把离线套件拷进去。
**SaoML 本身不在这里安装** —— 原因见第 4 节。

> **跳过本地构建**：推送到 `main` 后 GitHub Actions 会自动构建并推到 GHCR，
> 服务器上直接拉即可（镜像内容与本地 `docker build` 完全一致）：
>
> ```bash
> docker pull ghcr.io/cxk1725/saoml:8.15
> docker tag  ghcr.io/cxk1725/saoml:8.15 saoml:8.15
> ```
>
> 仓库 Actions 页面的构建会先跑一遍冒烟校验（套件可执行、分卷已合并、sshd 在 2222），
> 校验不过不会推送。离线场景在手动 Run workflow 时勾选 `export_tar` 下载 tar.gz。

---

## 4. 首次启动与安装

### 4.1 启动容器

```bash
cd docker
docker compose up -d
docker logs -f saoml          # 看到「尚未安装」横幅即可，Ctrl+C 退出日志
```

容器启动后，入口脚本会：
1. 往 `/etc/hosts` 写入 `127.0.0.1 oss.xq688.com.cn` 和 `file.xq688.com.cn`；
2. 启动本地资源伺服器（`127.0.0.1:80`）；
3. 交棒给 systemd。

### 4.2 执行安装

**另开一个终端**（不要动 `docker logs` 那个）：

```bash
docker exec -it saoml bash /opt/offline_kit/docker/install-in-container.sh
```

脚本会先检查 systemd 和三条资源路由，然后进入官方安装器。

### 4.3 交互答案（照抄）

| 安装器提问 | 输入 |
|---|---|
| 1.使用阿里YUM源 / 2.使用默认YUM源 | `1` |
| 输入括号中的SaoML官网按回车进行验证 | `ml.saoml.com.cn` |
| 1 - 全新安装 / 2 - 安装宝塔版 / 0 - 退出 | `1` |
| 请设置管理员后台地址，回车随机 | 回车（随机 5 位）或自定义 |
| 请设置数据库密码 | **自定义并立即记录**，别用 123456 |
| 请设置 APP 名称 | 回车（默认 SaoML加速器） |
| 已阅读，请回车开始继续 | 回车 |

之后是 8 步自动安装，约 10–30 分钟。**中途不要关终端。**

装完会打印：

```
管理员密码: xxxxx     <- 后台登录用，务必记下
数据库密码: xxxxx     <- 与上面输入的一致
```

> 忘了密码也不要紧，日志里有：
> `docker exec saoml grep -a '管理员密码' /var/log/saoml-install.log`

### 4.4 固化系统层（**重要，别跳过**）

安装器跑完后，SaoML 的系统部分（rpm 包、`/bin` 下的程序、systemd unit）都在容器的可写层里。
容器一旦被删除（`docker compose down`、`--build` 重建、Docker 清理），这些就全没了。

所以装完立刻做一次快照：

```bash
docker commit saoml saoml:8.15-installed
```

然后把 `docker-compose.yml` 里的 `image: saoml:8.15` 改成 `image: saoml:8.15-installed`。
以后重建容器会用这个镜像，系统层完整恢复，业务数据由数据卷提供。

### 4.5 重启并验证

```bash
docker restart saoml
```

重启后入口脚本检测到安装标记，恢复 iptables 与 `/root/res`，systemd 按原样拉起
mariadb、httpd、5 个 OpenVPN 实例、dnsmasq 与 saoml.service。

验证：

```bash
docker exec saoml systemctl status mariadb httpd saoml --no-pager
docker exec saoml ss -tlnp | grep -E ':(1024|8989|1194)'
```

面板地址：`http://服务器IP:1024/<管理员后台地址>`
（端口以安装器实际写入的 `httpd.conf` 为准）

---

## 5. 日常运维

```bash
# 启停
docker compose stop
docker compose start
docker compose restart

# 注意：装好之后不要用 docker compose up -d --build 重建容器，
#       --build 会用干净的基础镜像重建，rpm 装的系统层会全部丢失

# 进入容器
docker exec -it saoml bash

# 业务命令（原生命令全部可用）
docker exec -it saoml vpn            # 命令行工具箱
docker exec -it saoml systemctl status openvpn@server1194

# 日志
docker exec saoml tail -f /var/log/saoml_state.log
docker exec saoml tail -f /var/log/offline_http.log
```

### 备份与迁移（一条命令）

```bash
# 旧机器：停容器 → 导出镜像 + 5 个数据卷 → 打成单个 tar（结束自动启容器）
bash docker/backup.sh

# 输出：
#   /root/saoml-backup-20261023-0030.tar   ← 只拷这一个文件
```

```bash
# 新机器：装好 Docker，把上面那个 tar 拷过去，然后
tar xf saoml-backup-20261023-0030.tar
cd saoml-backup-20261023-0030
bash restore.sh
```

`restore.sh` 会自动做环境检查（cgroup / tun / 端口）、`docker load` 镜像、
创建 `docker_saoml_*` 卷并解回数据、再用包里的 compose 启动。

- 卷已存在时默认跳过，加 `--force` 覆盖
- 项目名已在 compose 里固定为 `name: docker`，所以卷名恒为 `docker_saoml_*`，
  与备份包解压到哪个目录无关
- 备份期间容器会短暂停止（保证 MySQL 一致），脚本退出时自动恢复；
  不想停可加 `--live`（不推荐）

> 不要试图用「原始镜像 + 数据卷」在新机器上恢复：系统层是空的，安装器又会因
> `/usr/bin/mysql` 已存在（数据卷里有）而拒绝安装。必须用 commit 出来的镜像。

完整说明（各卷内容、手工命令、注意事项）见 **[migrate.md](migrate.md)**。

### 彻底重装

```bash
cd docker
docker compose down -v        # -v 会删除数据卷，确认已备份！
docker compose up -d --build
```

---

## 6. 端口清单

| 端口 | 协议 | 用途 |
|---|---|---|
| 80 | tcp | 安装期资源伺服器（装完释放） |
| 1024 | tcp | 面板（httpd，可在 `vpn webport` 修改） |
| 53 | udp | dnsmasq（UDP 直连端口转发依赖） |
| 1194–1197 | tcp/udp | 4 个 OpenVPN 实例 |
| 443 / 3389 | tcp | proxy.bin / openvpn.bin 代理 |
| 8989 | tcp | saoml-service 命令通道 |
| 137 / 138 / 440 | tcp | 面板功能端口 |
| 3306 | tcp | 仅白名单功能开启时对外开放 |

因为是 host 网络，**不需要在 compose 里做端口映射**，但云厂商安全组要放行。

---

## 7. 故障排查

| 现象 | 原因与处理 |
|---|---|
| 容器起不来，`journalctl` 报 cgroup 错误 | 宿主是 cgroup v2。按第 2 节处理 |
| `systemctl` 报 `Failed to connect to bus` | 容器没以 `--privileged` 启动，或 `/sys/fs/cgroup` 没挂载 |
| 安装器提示「检测到服务器存在残留文件」 | 数据卷里有上次安装的 `/var/lib/mysql`。`docker compose down -v` 清干净 |
| 安装卡在下载 web-8.15.zip | 本地伺服器没起来或 80 被占。`docker exec saoml curl -I http://file.xq688.com.cn/8.15/web-8.15.zip` 自测 |
| yum 安装全 404 | 阿里云源不可达，或 DNS 异常。容器内 `curl -I http://mirrors.aliyun.com/centos/7/os/x86_64/repodata/repomd.xml` |
| 面板打开是空白/500 | PHP 的 SourceGuardian loader 未加载。检查 `php -m \| grep -i source` 与 `/etc/php.ini` 里的 `ixed.7.0.lin` |
| VPN 连上但不通外网 | 宿主 `net.ipv4.ip_forward=0`，或 iptables 规则没恢复。`docker exec saoml iptables -t nat -L -n` |
| 重启后 iptables 规则丢失 | 入口脚本靠 `/var/lib/saoml/iptables.bak` 恢复，确认该文件存在 |
| 53 端口冲突起不来 dnsmasq | 宿主有 `systemd-resolved`，停掉它或改成 127.0.0.53 |

---

## 8. 已知限制（务必知悉）

1. **容器里仍然是 EOL 的 CentOS 7.9**。这解决的是"宿主机可以升级"，不是"应用变新"。
   EL7 的 yum 源随时可能彻底下线，届时需要自己搭镜像源。
2. **面板核心 PHP 是 SourceGuardian 加密的**，配套 `ixed.7.0.lin`，PHP 版本被锁死在 7.0，**无法升级**。
3. **OpenVPN 锁定 2.4.3**：自研插件 `saoml_limit.so` 依赖 2.4 的插件 ABI，不能换 2.6。
4. **特权容器隔离性弱**：容器内的 iptables 直接改的是宿主规则，删容器不会自动清理。
5. **容器内 systemd** 是 hack 用法，升级 Docker/内核后需要重新验证。
6. 本方案**不提供**面板功能的二次开发能力（源码加密 + 混淆）。

---

## 9. 附：不使用 Compose 的启动命令

```bash
docker run -d --name saoml \
  --privileged --network=host --cgroupns=host \
  --device /dev/net/tun \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  -v saoml_mysql:/var/lib/mysql \
  -v saoml_openvpn:/etc/openvpn \
  -v saoml_www:/var/www \
  -v saoml_state:/var/lib/saoml \
  -v saoml_log:/var/log \
  --tmpfs /run --tmpfs /tmp \
  --stop-signal SIGRTMIN+3 \
  --restart unless-stopped \
  saoml:8.15
```

---

## 10. 真机实测记录（2026-10-22，CentOS 7.9 + Docker 26.1.4）

已在 IP `47.120.35.74`（CentOS 7.9 / cgroup v1 / 3.6G 内存）完整跑通并验证：
镜像构建 → 容器启动 → systemd 正常 → 安装器 8 步全过 → 面板可访问 → commit 固化 → 重建容器自愈。

过程中踩到 5 个坑，均已修复并固化进本目录文件：

| # | 现象 | 根因 | 修复 |
|---|---|---|---|
| 1 | `警告！chattr异常！脚本停止！` | `centos:7` 精简镜像删掉了 `e2fsprogs` 里的 `chattr` | Dockerfile 显式安装 `e2fsprogs` |
| 2 | `警告！SELinux关闭失败！脚本停止！` | 容器内 `setenforce` 必然返回非 0；且无 `/etc/selinux/config` | Dockerfile 创建 config 并把 `setenforce` 换成返回 0 的包装脚本 |
| 3 | `请不要多开SSH窗口运行` | 安装器用 `who \| wc -l` 判断会话数；`docker exec` 没有登录会话（who=0）被判定异常 | 容器内启用 sshd(2222)，安装脚本通过 `ssh -tt` 建立真实会话 |
| 4 | 卡在卡密验证/输入错位 | `cracked_stage5.sh` 只跳过第一层远程校验，安装器还有一层本地「输入 ml.saoml.com.cn」 | expect 自动应答（`auto-install.exp`） |
| 5 | php70w 装不上 | Dockerfile 预装 unzip 导致安装器跳过「更新 YUM 源」，连带没写入 `SaoML_PHP.repo` | entrypoint 首次启动时补 `SaoML_PHP.repo` |

**实测账号信息（该测试机）**：管理员密码 `admin`，后台路径 `/295b1`，
访问 `http://<IP>:1024/295b1/`；数据库 root 密码为安装时设定值。

**注意**：安装器对「登录会话」敏感，务必走 `install-in-container.sh`（内部用 SSH 会话），
不要手工 `docker exec` 里直接跑 `bash cracked_stage5.sh`。

| 6 | 后台「生成软件」失败 | `/tmp` 挂载为 tmpfs 时默认 `noexec`，apktool 打包需执行临时 jar：`could not exec: /tmp/brut_util_Jar_xxx.tmp` | compose 中把 `/tmp` 写成 `/tmp:exec,mode=1777`，重建容器 |

| 7 | 后台「生成软件」报“任务提交失败,或当前任务较多” | 面板自带 `shell/appgf` 在根目录 `mkdir /APP`，而 httpd 以 **apache** 用户运行，无权限写 `/`；脚本还会先 `rm -rf saoml.apk`，导致模板包被删、新包没生成 | 脚本改用可写的 `/APP`（`rm -rf /APP/*` + `cp -ri .../APP/. /APP/`），并预建 `/APP` 属主 apache；entrypoint 每次启动确保该目录存在 |

---

## 11. APP 安装包生成（重要修复）

后台「生成软件」按钮走的是面板自带的 `shell/appgf`，这条链路有三个问题，且都不会报错：

1. 脚本在**根目录** `mkdir /APP`，而 httpd 以 **apache** 身份运行，`/` 不可写 → 失败
2. `apktool` / `signapk` 的返回码没检查，`>/dev/null` 吞掉所有错误 → 失败也报"编译成功"
3. 先 `rm 下载站的包` 再 `cp 新包`，中途失败就永久失去安装包

结果：下载站上是**未注入服务器地址的模板包**（`server_host = http://IP:PORT`），
用户装上就是"没网"。

### 11.1 加固版构建脚本

`docker/panel/build-apk.sh` 替换了原脚本，行为：

- 全程在临时文件里做，所有步骤检查返回码
- 用 Python 替换字符串（避 sed 对 `/ & |` 的转义问题）
- **XML 实体转义**：应用名含 `&` `<` `>` 也不会破坏 `strings.xml`
- 打包前清 `build/` 缓存（否则新改的 `strings.xml` 不进包）
- **校验 APK 里确实注入了 IP**，且没有 `IP:PORT` 残留
- 校验通过才 `mv` 原子替换；任何失败都保留原包

手工调用：

```bash
docker exec saoml bash /opt/offline_kit/docker/panel/build-apk.sh \
  saoml.apk 47.120.35.74 1024 "SaoML加速器" net.saoml.m ""
#          输出文件    IP           端口  应用名        包名        代理key(可空)
```

代理版（输出 `daili.apk`，第 6 个参数是代理 key，会替换模板里的 `dailikey`）：

```bash
docker exec saoml bash /opt/offline_kit/docker/panel/build-apk.sh \
  daili.apk 47.120.35.74 1024 "SaoML加速器" net.saoml.m "代理KEY"
```

### 11.2 自愈

`entrypoint.sh` 每次启动会：

1. 把 `docker/panel/appgf`、`appdl` 覆盖到 `/var/www/html/shell/`（幂等）
2. 后台拉起 `heal-apk.sh`：如果下载站的包仍是 `http://IP:PORT` 占位符，
   等 MySQL 就绪后自动从 `map` 表读 `host` 重新构建

所以哪怕数据卷被换、包被覆盖，重启容器就能自动修回来。

### 11.3 校验

```bash
docker exec saoml sh -c "unzip -p /var/www/html/saoml.apk resources.arsc | strings | grep http://"
# 正常： http://47.120.35.74:1024
# 异常： http://IP:PORT
```

### 11.4 服务器地址从哪里取

APK 里的 `server_host` 必须是一个**真实可达的 IP 或域名**。取值的优先级：

1. `web_fwq.ipport` —— 安装器自己检测到的公网地址（如 `47.120.35.74:1024`），**首选**
2. `map.host` —— 后台「APP 设置」里的服务器地址，**全新安装时默认是中文占位「流控地址」**

`build-apk.sh` 会校验 IP 格式，中文占位符直接拒绝：

```
[失败] IP/域名不合法：'流控地址'（不能是中文或占位符，否则 APP 连不上）
```

所以看到这个报错，去后台把「APP 设置 → 服务器地址」填成真实 IP，
或者确认 `web_fwq` 表里有正确记录。

### 11.5 排错

```bash
docker exec saoml cat /tmp/saoml-apk.log
```

常见原因：

| 日志 | 原因 |
|---|---|
| `apktool 打包失败` | 应用名含未转义字符（本脚本已处理），或磁盘满 |
| `校验不通过：仍残留 IP:PORT` | 模板被改过，`server_host` 不是 `http://IP:PORT` |
| `校验不通过：未找到 <IP>` | `apktool` 用了旧缓存（脚本已 `rm -rf build/`） |
