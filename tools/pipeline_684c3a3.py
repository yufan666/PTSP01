# -*- coding: utf-8 -*-
"""后台流水线：等 run 42625247244 (684c3a3b) 构建完成 -> 下载 -> 重压 -> 放根目录。

用法：
    export GHTOK=$(cat /tmp/ghtok)
    python -u "C:/Users/ghost/WorkBuddy/插排工具箱_PTSP01/PTSP01-repo/tools/pipeline_684c3a3.py"

步骤：
  1. 每 90s 轮询 run 状态，直到 completed（最长等 4 小时）
  2. 成功 -> 列 artifacts -> curl 下载两个 zip（urllib 跨域重定向带鉴权头会 401）
  3. 解包到 构建_684c3a3b_工具进镜像/dl_684c3a3b/
  4. repack_uimage.py 重压为 dict1m breed 可引导镜像
  5. 拷贝到归档根目录 initramfs-684c3a3b-dict1m.bin
  6. 校验 LZMA 头（props=0x5d / dict=0x00100000 / size=真实解压长度）
"""
import io
import json
import os
import shutil
import struct
import subprocess
import sys
import time
import zipfile
import urllib.request
import urllib.error

REPO = "yufan666/PTSP01"
API = "https://api.github.com/repos/" + REPO
RUN_ID = "42625247244"
TOK = os.environ.get("GHTOK") or ""
if not TOK:
    sys.exit("请先 export GHTOK=...")

ARCHIVE = r"C:\Users\ghost\Desktop\邦讯玩儿插排\16_openwrt\02_自制镜像\云编译v25.12.0_DEVMEM修复_20261109"
BUILD_DIR = os.path.join(ARCHIVE, "构建_684c3a3b_工具进镜像")
DL_DIR = os.path.join(BUILD_DIR, "dl_684c3a3b")
REPACK = os.path.join(ARCHIVE, "脚本_PC工具", "repack_uimage.py")
FINAL_NAME = "initramfs-684c3a3b-dict1m.bin"


def api(path):
    req = urllib.request.Request(API + path)
    req.add_header("Authorization", "Bearer " + TOK)
    req.add_header("Accept", "application/vnd.github+json")
    for attempt in range(5):
        try:
            with urllib.request.urlopen(req, timeout=120) as r:
                return json.loads(r.read().decode())
        except Exception as e:
            print("api 重试 %d/5: %s" % (attempt + 1, e))
            time.sleep(20)
    raise RuntimeError("api 连续失败: " + path)


def wait_run():
    deadline = time.time() + 4 * 3600
    while time.time() < deadline:
        d = api("/actions/runs/%s" % RUN_ID)
        print("[%s] run status=%s conclusion=%s" % (
            time.strftime("%H:%M:%S"), d["status"], d["conclusion"]))
        if d["status"] == "completed":
            return d["conclusion"]
        time.sleep(90)
    raise RuntimeError("等待超时")


def curl_download(url, dest):
    # curl 跨域重定向会自动丢鉴权头，urllib 不会（会 401）
    subprocess.run(
        ["curl", "-sSL", "--fail", "-H", "Authorization: Bearer " + TOK,
         "-o", dest, url], check=True)


def main():
    print("=== 1. 等构建 ===")
    concl = wait_run()
    if concl != "success":
        sys.exit("run %s 结论: %s" % (RUN_ID, concl))

    print("=== 2. 下载 artifacts ===")
    os.makedirs(DL_DIR, exist_ok=True)
    arts = api("/actions/runs/%s/artifacts" % RUN_ID)["artifacts"]
    print("artifacts:", [(a["name"], a["size_in_bytes"]) for a in arts])
    for a in arts:
        if not (a["name"].startswith("openwrt-ptsp01") or a["name"].startswith("ptsp01-tools")):
            continue
        dest = os.path.join(DL_DIR, a["name"] + ".zip")
        print("curl 下载 %s ..." % a["name"])
        curl_download("https://api.github.com/repos/%s/actions/artifacts/%s/zip" % (REPO, a["id"]), dest)
        print("  %d 字节" % os.path.getsize(dest))
        with zipfile.ZipFile(dest) as zf:
            for n in zf.namelist():
                if n.endswith("/"):
                    continue
                base = os.path.basename(n)
                if base:
                    with open(os.path.join(DL_DIR, base), "wb") as f:
                        f.write(zf.read(n))
                    print("  -> " + base)

    print("=== 3. 找 initramfs 并重压 ===")
    src = None
    for n in os.listdir(DL_DIR):
        if n.endswith(".bin") and "initramfs" in n:
            src = os.path.join(DL_DIR, n)
            break
    if not src:
        sys.exit("没找到 initramfs .bin: %s" % os.listdir(DL_DIR))
    out = os.path.join(BUILD_DIR, FINAL_NAME)
    subprocess.run([sys.executable, REPACK, src, out], check=True)
    print("重压完成: %s (%d 字节)" % (out, os.path.getsize(out)))

    print("=== 4. 放到 HTTP 根目录 ===")
    final = os.path.join(ARCHIVE, FINAL_NAME)
    shutil.copyfile(out, final)
    print("已放置: " + final)

    print("=== 5. 校验 LZMA 头 ===")
    with open(final, "rb") as f:
        f.seek(64)  # 跳过 uImage 头
        hdr = f.read(13)
    props, dictsz, rawsz = hdr[0], struct.unpack("<I", hdr[1:5])[0], struct.unpack("<Q", hdr[5:13])[0]
    print("props=0x%02x dict=0x%08x size=%d" % (props, dictsz, rawsz))
    ok = props == 0x5D and dictsz == 0x00100000 and rawsz > 20_000_000
    print("校验: %s" % ("OK" if ok else "FAIL"))
    print("=== PIPELINE DONE ===")


if __name__ == "__main__":
    main()
