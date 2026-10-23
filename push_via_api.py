#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
通过 GitHub REST API 推送仓库（不需要 git 协议，也不需要 github.com 可达）。

适用场景：本机只能访问 api.github.com，git push 走 github.com:443 不通。

用法：
    1. 在 https://github.com/settings/tokens 生成 token（勾选 repo 权限）
    2. 把 token 存到 C:\\Users\\Administrator\\Desktop\\token.txt（一行，别加引号）
    3. python push_via_api.py
"""
import os
import sys
import json
import base64
import time
import urllib.request
import urllib.error

OWNER = "cxk1725"
REPO = "saoMlopneVpn"
BRANCH = "main"
ROOT = os.path.dirname(os.path.abspath(__file__))
TOKEN_FILE = os.path.join(os.path.dirname(ROOT), "token.txt")
API = "https://api.github.com"

COMMIT_MSG = """feat: SaoML 8.15 离线部署套件（Docker + 裸机）

- 全离线：作者域名 xq688.com.cn 不可用也能装完
- Docker：centos:7 + systemd 整机封装，宿主系统不限（需 cgroup v1）
- 裸机：CentOS 7 一键 offline_install.sh
- 迁移：backup.sh / restore.sh 一条命令导出恢复
- 修复 8 个实测坑，其中 APP 生成改为加固版（注入校验 + 失败保留旧包 + 启动自愈）"""


def load_token():
    if not os.path.exists(TOKEN_FILE):
        sys.exit("找不到 token 文件：%s" % TOKEN_FILE)
    t = open(TOKEN_FILE, encoding="utf-8").read().strip()
    if not t or len(t) < 20:
        sys.exit("token 内容不像有效值（长度 %d）" % len(t))
    return t


TOKEN = load_token()


def api(method, path, data=None, timeout=600):
    url = API + path
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, method=method)
    req.add_header("Authorization", "token " + TOKEN)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", "saoMlopneVpn-pusher")
    if body:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            txt = r.read().decode("utf-8")
            return json.loads(txt) if txt else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:500]
        raise RuntimeError("HTTP %s %s %s -> %s" % (e.code, method, path, detail))


def collect_files():
    """收集要上传的文件，跳过 .git 和 .gitignore 里列的东西"""
    skip_dirs = {".git", ".idea", ".vscode", "__pycache__"}
    out = []
    for dirpath, dirnames, filenames in os.walk(ROOT):
        dirnames[:] = [d for d in dirnames if d not in skip_dirs]
        for fn in filenames:
            if fn in ("push_via_api.py", ".push_cache.json"):
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, ROOT).replace("\\", "/")
            out.append((rel, full))
    return sorted(out)


def main():
    # 1. 仓库信息
    try:
        info = api("GET", "/repos/%s/%s" % (OWNER, REPO))
        print("[1/5] 仓库 %s/%s 可访问，默认分支 %s" % (OWNER, REPO, info.get("default_branch")))
    except RuntimeError as e:
        sys.exit("无法访问仓库（token 权限不足或仓库不存在）：%s" % e)

    # 2. 现有分支（首次推送时仓库可能只有 README）
    parent_sha = None
    try:
        ref = api("GET", "/repos/%s/%s/git/ref/heads/%s" % (OWNER, REPO, BRANCH))
        parent_sha = ref["object"]["sha"]
        print("      已有分支 %s，父提交 %s" % (BRANCH, parent_sha[:8]))
    except RuntimeError:
        print("      分支 %s 还不存在，将创建首个提交" % BRANCH)

    # 空仓库不能直接建 blob（API 返回 409 Git Repository is empty），
    # 先用 Contents API 落一个占位文件制造首个 commit，稍后用完整 tree 覆盖
    if not parent_sha:
        api("PUT", "/repos/%s/%s/contents/.bootstrap" % (OWNER, REPO), {
            "message": "chore: bootstrap",
            "content": base64.b64encode(b"bootstrap\n").decode("ascii"),
            "branch": BRANCH,
        })
        ref = api("GET", "/repos/%s/%s/git/ref/heads/%s" % (OWNER, REPO, BRANCH))
        parent_sha = ref["object"]["sha"]
        print("      已创建初始提交 %s" % parent_sha[:8])

    # 3. 上传 blob
    # 超过阈值的文件走不通（代理会在长连接上截断大请求体），
    # 仓库里已改为分卷存放，单个 blob 保持在 10 MB 以内。
    MAX_MB = int(os.environ.get("MAX_BLOB_MB", "10"))
    MAX_BYTES = MAX_MB * 1024 * 1024
    files = collect_files()
    skipped = [(r, f) for r, f in files if os.path.getsize(f) > MAX_BYTES]
    files = [(r, f) for r, f in files if os.path.getsize(f) <= MAX_BYTES]
    total = len(files)

    # 断点续传：已上传成功的 blob 记在 .push_cache.json 里，中断后重跑不重复传
    cache_path = os.path.join(ROOT, ".push_cache.json")
    cache = {}
    if os.path.exists(cache_path):
        try:
            cache = json.loads(open(cache_path, encoding="utf-8").read())
        except Exception:
            cache = {}
    print("[2/5] 上传 %d 个文件（已缓存 %d，跳过 %d 个超限）"
          % (total, len(cache), len(skipped)))
    for r, f in skipped:
        print("      跳过 %-40s %6.1f MB" % (r, os.path.getsize(f) / 1048576.0))

    tree = []
    for i, (rel, full) in enumerate(files, 1):
        size = os.path.getsize(full)
        if rel in cache:
            tree.append({"path": rel, "mode": "100644", "type": "blob", "sha": cache[rel]})
            continue
        for attempt in range(4):
            try:
                content = base64.b64encode(open(full, "rb").read()).decode("ascii")
                r = api("POST", "/repos/%s/%s/git/blobs" % (OWNER, REPO),
                        {"content": content, "encoding": "base64"})
                tree.append({"path": rel, "mode": "100644", "type": "blob", "sha": r["sha"]})
                cache[rel] = r["sha"]
                json.dump(cache, open(cache_path, "w", encoding="utf-8"))
                print("      [%d/%d] %-42s %7.2f MB" % (i, total, rel[-42:], size / 1048576.0))
                break
            except Exception as e:
                if attempt == 3:
                    json.dump(cache, open(cache_path, "w", encoding="utf-8"))
                    sys.exit("上传失败 %s: %s" % (rel, e))
                wait = 5 * (attempt + 1)
                print("      重试(%d) %s：%s" % (attempt + 1, rel, str(e)[:70]))
                time.sleep(wait)

    # 4. 建 tree / commit
    print("[3/5] 创建 tree")
    tree_r = api("POST", "/repos/%s/%s/git/trees" % (OWNER, REPO), {"tree": tree})
    print("[4/5] 创建 commit")
    payload = {"message": COMMIT_MSG, "tree": tree_r["sha"]}
    if parent_sha:
        payload["parents"] = [parent_sha]
    commit = api("POST", "/repos/%s/%s/git/commits" % (OWNER, REPO), payload)
    print("      commit %s" % commit["sha"][:8])

    # 5. 更新分支
    print("[5/5] 更新分支 %s" % BRANCH)
    if parent_sha:
        api("PATCH", "/repos/%s/%s/git/refs/heads/%s" % (OWNER, REPO, BRANCH),
            {"sha": commit["sha"], "force": False})
    else:
        api("POST", "/repos/%s/%s/git/refs" % (OWNER, REPO),
            {"ref": "refs/heads/" + BRANCH, "sha": commit["sha"]})

    print("\n完成：https://github.com/%s/%s" % (OWNER, REPO))
    print("共 %d 个文件，commit %s" % (total, commit["sha"][:8]))


if __name__ == "__main__":
    main()
