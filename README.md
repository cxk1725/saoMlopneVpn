# SaoML 8.15 离线部署套件

把 SaoML 面板（PHP + MariaDB + OpenVPN 多节点）装进 Docker 容器，或者直接装在 CentOS 7 上。**所有安装资源已本地化**，作者域名 `xq688.com.cn` 挂了也能装完。

## 两种部署方式

| | Docker（推荐） | CentOS 7 裸机 |
|---|---|---|
| 宿主机系统 | 任意 Linux（**需 cgroup v1**） | 必须 CentOS 7 x64 |
| 部署耗时 | 约 10 分钟 | 约 20 分钟 |
| 换机器 | 一条命令导出/恢复 | 从头重装 |
| 回滚 | 换镜像 tag | 无 |
| 隔离性 | 特权容器（等同轻量虚拟机） | 原生 |
| 适合 | 新机器、要迁移、要多环境 | 已有 CentOS 7、追求最少层 |

> 面板包以分卷形式随仓库分发，Docker 构建和 `offline_install.sh` 都会自动合并，
> 无需手动处理。要单独还原：`bash file_8.15/merge-parts.sh`

> **cgroup v1 是硬前提**：`centos:7` 里的 systemd 219 不支持 cgroup v2。
> CentOS 7/8、Ubuntu 20.04、Debian 11 默认都是 v1；Ubuntu 22.04+ / Debian 12 默认 v2，需要先切回。

## 快速开始

### 方式一：Docker

```bash
# 0. 环境自检（cgroup / tun / 端口 / iptables / 磁盘）
bash docker/check-host.sh

# 1. 构建基础镜像（约 5 分钟）
docker build -f docker/Dockerfile -t saoml:8.15 .

# 2. 启动容器
cd docker && docker compose up -d

# 3. 安装（脚本会通过容器内 sshd 建立真实会话，安装器要求）
docker exec -it saoml bash /opt/offline_kit/docker/install-in-container.sh

# 4. 装完立刻固化系统层（重要）
docker commit saoml saoml:8.15-installed
```

交互答案照抄：

```
ml.saoml.com.cn     ← 卡密验证
1                   ← 全新安装
（直接回车）          ← 后台地址，随机生成
（自定义密码）        ← 数据库密码
（直接回车）          ← APP 名称
（直接回车）          ← 开始安装
```

完整说明见 **[docs/docker.md](docs/docker.md)**。

### 方式二：CentOS 7 裸机

```bash
# 整个目录上传到 /root/offline_kit，然后
cd /root/offline_kit
bash offline_install.sh      # 资源自检 + hosts 劫持 + 起本地资源服务器
xsaoml                       # 或 bash cracked_stage5.sh
```

完整说明见 **[docs/baremetal.md](docs/baremetal.md)**。

## 迁移 / 备份

```bash
# 旧机器：停容器 → 导出镜像 + 5 个数据卷 → 打成单个 tar（结束自动启容器）
bash docker/backup.sh

# 新机器：一条命令恢复
tar xf saoml-backup-*.tar && cd saoml-backup-* && bash restore.sh
```

详见 **[docs/migrate.md](docs/migrate.md)**。

## 目录结构

```
.
├── docker/                     # Docker 部署
│   ├── Dockerfile              # centos:7 + systemd + 离线套件
│   ├── docker-compose.yml      # 特权 / host 网络 / tun / 5 个数据卷
│   ├── entrypoint.sh           # 容器入口：hosts 劫持、脚本加固、APK 自愈
│   ├── install-in-container.sh # 安装引导（SSH 真实会话 + expect）
│   ├── auto-install.exp        # 安装器自动应答
│   ├── check-host.sh           # 宿主机自检
│   ├── backup.sh / restore.sh  # 迁移导出 / 恢复
│   └── panel/                  # 面板「生成软件」加固版脚本
│       ├── build-apk.sh        # 构建 APK：注入校验 + 失败不覆盖 + 原子替换
│       ├── heal-apk.sh         # 下载站 APK 自愈
│       └── appgf / appdl       # 面板调用入口（主站包 / 代理包）
├── docs/                       # 文档
├── offline_install.sh          # 裸机部署入口
├── xsaoml                      # 官方安装器
├── cracked_stage5.sh           # 免卡密入口
├── httpserver                  # 本地资源伺服器（Go 静态编译）
├── offline_http_server.py      # 资源伺服器 Python 备选
├── oss_yum_public/             # yum 源配置 + unzip
├── oss_yum_php_el7/            # php70w 仓库（49 rpm）
└── file_8.15/                  # 面板程序包（48 MB，拆成 10 个 5 MB 分卷）
```

## 部署后

| 项目 | 地址 |
|---|---|
| 用户端 | `http://服务器IP:1024/` |
| 管理后台 | `http://服务器IP:1024/<随机5位>/`（装完会打印） |
| APP 下载 | `http://服务器IP:1024/saoml.apk` |

管理后台地址和密码、数据库密码都在安装日志里：

```bash
docker exec saoml grep -aE "管理员密码|管理员地址|数据库密码" /var/log/saoml-install.log
```

## 已修复的坑

这套文件在真实 CentOS 7 + Docker 26 上完整跑通过，以下问题都已修好并写进脚本：

| # | 现象 | 原因 |
|---|---|---|
| 1 | `chattr异常` 安装中止 | `centos:7` 精简镜像删了 `e2fsprogs` 里的 chattr |
| 2 | `SELinux关闭失败` 安装中止 | 容器内 `setenforce` 必然返回非 0 |
| 3 | `请不要多开SSH窗口` | 安装器用 `who \| wc -l` 判断；`docker exec` 没有登录会话 |
| 4 | 卡在卡密验证 | 安装器有第二层本地验证（需输入 `ml.saoml.com.cn`） |
| 5 | php70w 装不上 | 预装 unzip 导致安装器跳过 YUM 源更新，没写 `SaoML_PHP.repo` |
| 6 | 后台生成软件失败 | 脚本在根目录 `mkdir /APP`，httpd 是 apache 身份，无权限 |
| 7 | **APP 装上没网** | 生成失败后仍报"成功"，把未注入地址的模板包放上了下载站 |
| 8 | 应用名含 `&` 时打包失败 | XML 实体未转义，原脚本静默失败 |
| 9 | 安装中途 `ssh: command not found` | 镜像只装了 `openssh-server`，安装脚本要用 `ssh` 建真实会话 |
| 10 | APK 地址变成 `http://流控地址:1024` | 新装库里 `map.host` 是中文占位符，真实 IP 在 `web_fwq.ipport` |

第 7、8 条是同一个根因：原脚本不检查 apktool/signapk 返回码，失败也报"编译成功"。
`docker/panel/build-apk.sh` 现在会校验 APK 里确实注入了服务器地址，校验不过就保留旧包，
从根上杜绝"坏包上线"。

## 常见问题

**Q：容器起不来，systemd 报错？**
宿主机是 cgroup v2。切回 v1：
```bash
grubby --update-kernel=ALL --args="systemd.unified_cgroup_hierarchy=0" && reboot
```

**Q：后台点「生成软件」提示"任务提交失败，或当前任务较多"？**
这是面板自身（SourceGuardian 加密）的任务队列判断，与本套件无关。
APK 生成功能已由 `docker/panel/build-apk.sh` 独立实现，可不依赖该按钮：

```bash
docker exec saoml bash /opt/offline_kit/docker/panel/build-apk.sh \
  saoml.apk <公网IP> 1024 "应用名称" net.saoml.m ""
```

**Q：APP 装上提示没网 / 一直转圈？**
检查下载站上的包是否真的注入了地址：
```bash
docker exec saoml sh -c "unzip -p /var/www/html/saoml.apk resources.arsc | strings | grep http://"
```
正常应显示 `http://你的IP:1024`；如果显示 `http://IP:PORT`，执行 `build-apk.sh` 重新生成，
或重启容器让 `heal-apk.sh` 自动修复。

**Q：换机器要重装吗？**
不用。`docker/backup.sh` 导出、`restore.sh` 恢复即可，见 [docs/migrate.md](docs/migrate.md)。

## 版权

安装器、面板程序、OpenVPN 插件的版权归各自作者所有。本仓库只做离线资源整理与容器化封装。
