#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SaoML 离线资源伺服器（替代 oss.xq688.com.cn / file.xq688.com.cn）

配合 /etc/hosts 劫持使用，让原版安装器的所有下载全部命中本地磁盘：
  /yum/public/*        -> oss_yum_public/*     (unzip/Killuser/4个repo)
  /yum/php/el7/*       -> oss_yum_php_el7/*    (395 rpm + repodata 完整yum仓库)
  /8.15/*              -> file_8.15/*          (web-8.15.zip 面板包)

用法（root）：python3 offline_http_server.py            # 监听 127.0.0.1:80
"""
import os
import sys
from http.server import SimpleHTTPRequestHandler, HTTPServer

ROOT = os.path.dirname(os.path.abspath(__file__))

ROUTES = [
    ("/yum/public/", os.path.join(ROOT, "oss_yum_public")),
    ("/yum/php/el7/", os.path.join(ROOT, "oss_yum_php_el7")),
]


class Handler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def translate_path(self, path):
        path = path.split("?", 1)[0].split("#", 1)[0]
        for prefix, base in ROUTES:
            if path.startswith(prefix):
                rel = path[len(prefix):].lstrip("/")
                return os.path.join(base, *rel.split("/"))
        if path.startswith("/8.15/"):
            rel = path[len("/8.15/"):].lstrip("/")
            return os.path.join(ROOT, "file_8.15", *rel.split("/"))
        return os.path.join(ROOT, "__404__")

    def log_message(self, fmt, *args):
        sys.stderr.write("[http] %s %s\n" % (self.address_string(), fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 80
    bind = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1"
    srv = HTTPServer((bind, port), Handler)
    print(f"[*] offline resource server on {bind}:{port}")
    print("[*] hosts 应包含: 127.0.0.1 oss.xq688.com.cn / 127.0.0.1 file.xq688.com.cn")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[*] stopped")
