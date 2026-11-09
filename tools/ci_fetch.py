#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""下载某次 run 的产物（固件 zip + ptsp01-tools），并解包到指定目录。

用法：
    python tools/ci_fetch.py <run_id> [目标目录]

行为：
    - 列出该 run 的 artifacts
    - 下载 openwrt-ptsp01-* 与 ptsp01-tools 两个 zip
    - 把里面的 *.bin / *.manifest / spitest / pl7223bb / devmem 解到目标目录
"""
import io
import json
import os
import sys
import urllib.error
import urllib.request
import zipfile

REPO = "yufan666/PTSP01"
API = "https://api.github.com/repos/" + REPO
TOK = os.environ.get("GHTOK") or ""


def call(path, raw=False, follow=None):
    url = follow or (API + path)
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + TOK)
    req.add_header("Accept", "application/vnd.github+json")
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            if raw:
                return r.read()
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        sys.exit("HTTP %s %s: %s" % (e.code, url, e.read().decode()[:300]))


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    run_id = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else "."
    os.makedirs(out, exist_ok=True)

    arts = call("/actions/runs/%s/artifacts" % run_id)["artifacts"]
    if not arts:
        sys.exit("该 run 没有产物（可能失败了）")
    for a in arts:
        print("artifact: %-32s %8.1f KB  过期 %s" % (
            a["name"], a["size_in_bytes"] / 1024, a["expires_at"][:10]))

    for a in arts:
        if not (a["name"].startswith("openwrt-ptsp01") or a["name"].startswith("ptsp01-tools")):
            continue
        print("\n下载 %s ..." % a["name"])
        blob = call(None, raw=True,
                    follow="https://api.github.com/repos/%s/actions/artifacts/%s/zip" % (REPO, a["id"]))
        print("  %d 字节" % len(blob))
        zf = zipfile.ZipFile(io.BytesIO(blob))
        for n in zf.namelist():
            if n.endswith("/"):
                continue
            base = os.path.basename(n)
            if not base:
                continue
            dest = os.path.join(out, base)
            with open(dest, "wb") as f:
                f.write(zf.read(n))
            os.chmod(dest, 0o755)
            print("  -> %-58s %d 字节" % (base, os.path.getsize(dest)))


if __name__ == "__main__":
    main()
