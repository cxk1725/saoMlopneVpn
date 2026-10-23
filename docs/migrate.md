# 迁移 / 备份 / 恢复

Docker 方式的 SaoML 由两部分组成：**镜像（系统层）+ 数据卷（业务数据）**。两者都要带走，缺一不可。

- 只有镜像 → 是个干净的系统，没有用户和线路数据
- 只有数据卷 → 系统层是空的，服务起不来

## 一条命令导出

在**已部署好**的机器上：

```bash
bash docker/backup.sh
```

脚本做的事：

1. 停止容器（保证 MySQL 数据一致），脚本退出时自动重新启动
2. `docker save` 导出 `saoml:8.15-installed`（约 1.6 GB → 压缩后 700 MB 左右）
3. 逐个导出 5 个数据卷
4. 复制 `docker/` 部署文件
5. 生成 `meta.txt`（镜像 ID、卷大小、SHA256）
6. 打包成单个 `.tar`

产物：

```
/root/saoml-backup-20261023-0037.tar          706 MB   ← 只拷这一个文件
```

参数：

| 参数 | 说明 |
|---|---|
| `bash docker/backup.sh /data/bak` | 指定输出目录 |
| `bash docker/backup.sh --live` | 不停止容器（不推荐，MySQL 可能不一致） |

## 一条命令恢复

新机器上装好 Docker，把 `.tar` 拷过去：

```bash
tar xf saoml-backup-20261023-0037.tar
cd saoml-backup-20261023-0037
bash restore.sh
```

`restore.sh` 会：

1. 检查 Docker / cgroup / tun / 端口
2. `docker load` 镜像
3. 创建 `docker_saoml_*` 卷并解回数据
4. 用包里的 compose 启动（`--no-build`）

参数：

| 参数 | 说明 |
|---|---|
| `bash restore.sh /path/to/xxx.tar` | 直接给 tar，自动解包 |
| `bash restore.sh <目录>` | 指定已解包的目录 |
| `bash restore.sh <路径> --force` | 数据卷已存在时强制覆盖 |

> 卷名固定为 `docker_saoml_*`（compose 里写死了 `name: docker`），
> 所以备份包解压到哪个目录都能正确恢复。

## 验证

```bash
docker ps --format '{{.Names}} {{.Status}} {{.Image}}'
docker exec saoml systemctl is-active mariadb httpd saoml
curl -I http://127.0.0.1:1024/
```

## 手工方式（脚本不可用时）

```bash
# 导出镜像
docker save saoml:8.15-installed | gzip -1 > image.tar.gz

# 导出数据卷
mkdir -p backup
for v in mysql www openvpn state log; do
  docker run --rm -v docker_saoml_$v:/data:ro -v $PWD/backup:/backup \
    saoml:8.15-installed tar czf /backup/vol-$v.tar.gz -C /data .
done

# ---- 新机器 ----
gzip -dc image.tar.gz | docker load
for v in mysql www openvpn state log; do
  docker volume create docker_saoml_$v
  docker run --rm -v docker_saoml_$v:/data -v $PWD/backup:/backup \
    saoml:8.15-installed tar xzf /backup/vol-$v.tar.gz -C /data
done
cd docker && docker compose up -d --no-build
```

## 各卷内容

| 卷 | 内容 | 丢了会怎样 |
|---|---|---|
| `docker_saoml_mysql` | 用户、线路、订单、配置 | 业务数据全没 |
| `docker_saoml_www` | 网站程序、后台、APK | 面板打不开 |
| `docker_saoml_openvpn` | 证书、密钥、服务端配置 | 客户端全部失效 |
| `docker_saoml_state` | iptables 备份、`/root/res` 备份 | 重启后 NAT 规则丢失 |
| `docker_saoml_log` | 日志 | 只影响排查 |

## 注意

- **不要用 `--build` 重建容器**。那会用干净的基础镜像重建，rpm 装的系统层全部丢失
  （数据卷还在，但服务起不来）。要重建请指定 `image: saoml:8.15-installed`。
- 恢复后管理员后台地址、密码**沿用原服务器**，不会变。
- 备份包里的 compose 已把 `image:` 固定为 `saoml:8.15-installed`；
  `restore.sh` 还会再兜底检查一次，避免误用基础镜像启动出空系统。
- 确认恢复成功后可以删掉解开的目录，省一半空间：
  `rm -rf /root/saoml-backup-20261023-0037`
