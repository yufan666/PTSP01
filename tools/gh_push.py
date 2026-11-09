#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
github.com 的 git 协议走不通（代理对 443 CONNECT 返回 502）时的备用推送通道：
用 api.github.com 的 Git Data API 构造一个 commit 并前移 main 指针。

用法：
    python tools/gh_push.py <token> "<commit message>"

它做的事：
    1. 读本地 HEAD 的 commit（parent）和 remote main（必须一致，防止覆盖别人的提交）
    2. 把 `git diff --name-only <remote>..HEAD` 里每个文件作为 blob 上传
    3. 基于 remote 的 tree + 这些 blob 建一棵新 tree
    4. 建 commit（parent = remote main），PATCH refs/heads/main
"""
import base64
import json
import os
import subprocess
import sys
import urllib.error
import urllib.request

REPO = os.environ.get("GH_REPO", "yufan666/PTSP01")
API = "https://api.github.com/repos/" + REPO


def api(method, path, token, payload=None):
    url = API + path
    data = None
    if payload is not None:
        data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        sys.exit("HTTP %s %s %s\n%s" % (e.code, method, url, body[:1500]))


def git(*args):
    return subprocess.check_output(["git"] + list(args)).decode().strip()


def main():
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    token, message = sys.argv[1], sys.argv[2]

    local_head = git("rev-parse", "HEAD")
    remote = api("GET", "/git/ref/heads/main", token)["object"]["sha"]
    print("本地 HEAD  :", local_head)
    print("远程 main  :", remote)

    # 快进校验：不用 commit 祖先（API 推的提交本地没有对象），改比树哈希。
    # remote 的树必须等于本地 HEAD~1 的树（即远端内容 = 本次提交之前的本地内容），
    # 或等于本地 HEAD 的树（远端已同步，只需前移指针）。
    remote_commit = remote
    remote = api("GET", "/git/commits/%s" % remote, token)["tree"]["sha"]
    parent = git("rev-parse", "HEAD~1")
    parent_tree = git("rev-parse", "HEAD~1^{tree}")
    head_tree = git("rev-parse", "HEAD^{tree}")
    print("远端 tree  :", remote)
    print("本地父 tree:", parent_tree)
    if remote == head_tree:
        print("远端内容已与本地 HEAD 一致，仅前移指针")
        api("PATCH", "/git/refs/heads/main", token, {"sha": local_head, "force": False})
        print("✓ main 已指到", local_head[:8])
        return
    if remote != parent_tree:
        sys.exit("!! 远端 tree 既不是本地父提交的树也不是 HEAD 的树，拒绝推送（内容已分叉）")
    changed = [p for p in git("diff", "--name-only", parent, local_head).splitlines() if p]
    print("待推送文件 (%d):" % len(changed))
    for p in changed:
        print("   ", p)

    entries = []
    for p in changed:
        full = os.path.join(os.getcwd(), p)
        if not os.path.exists(full):
            entries.append({"path": p, "mode": "100644", "type": "blob", "sha": None})
            print("   [删除]", p)
            continue
        with open(full, "rb") as f:
            raw = f.read()
        blob = api("POST", "/git/blobs", token, {
            "content": base64.b64encode(raw).decode(),
            "encoding": "base64",
        })
        executable = bool(os.stat(full).st_mode & 0o111)
        entries.append({
            "path": p,
            "mode": "100755" if executable else "100644",
            "type": "blob",
            "sha": blob["sha"],
        })
        print("   [ok] %s (%d 字节) -> %s" % (p, len(raw), blob["sha"][:8]))

    # 被删除的 path 传 sha=null，Git Data API 会剔除该条目（不能传全 0）
    tree = api("POST", "/git/trees", token, {"base_tree": remote, "tree": entries})
    print("新 tree:", tree["sha"])

    commit = api("POST", "/git/commits", token, {
        "message": message,
        "tree": tree["sha"],
        "parents": [remote_commit],
    })
    print("新 commit:", commit["sha"])

    api("PATCH", "/git/refs/heads/main", token, {"sha": commit["sha"], "force": False})
    print("✓ main 已前移到", commit["sha"][:8])
    print("   （本地 git status 会显示与 origin/main 分叉的假象，"
          "因为 github.com 连不上，fetch 不到；以这段输出为准）")


if __name__ == "__main__":
    main()
