# -*- coding: utf-8 -*-
"""push_api.py —— 走 GitHub git data API 推送本地 HEAD 与远端 main 的差异

用法（在仓库根目录）：
    python tools/push_api.py <commit-message>
token 从 audio-port/token.txt 读取（调用方负责写入与删除）

为什么需要它：本机 git 协议受代理干扰（CONNECT 502），gh_push.py 走 contents API
只能整文件替换且会丢可执行位；这里用 git data API 建 blob/tree/commit，再 PATCH 分支，
一次成型并且从本地 git 索引读取文件模式（100644/100755）。
"""
import base64
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.request

ssl._create_default_https_context = ssl._create_unverified_context

REPO = 'yufan666/PTSP01'
TOKEN_FILE = 'audio-port/token.txt'


def api(method, url, body=None, retries=6):
    token = open(TOKEN_FILE).read().strip()
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url, method=method,
                                         data=json.dumps(body).encode() if body else None)
            req.add_header('Authorization', 'Bearer ' + token)
            req.add_header('Accept', 'application/vnd.github+json')
            req.add_header('User-Agent', 'check')
            with urllib.request.urlopen(req, timeout=60) as r:
                return json.loads(r.read().decode())
        except Exception as e:
            print('  retry %d/%d (%s %s): %s' % (attempt + 1, retries, method,
                                                 url.split('/')[-1], e))
            time.sleep(6)
    raise RuntimeError('API 重试耗尽: ' + url)


def index_modes():
    """从本地 git 索引取每个文件模式（Windows 下 os.access 不可靠）"""
    out = subprocess.check_output(['git', 'ls-files', '-s']).decode()
    modes = {}
    for ln in out.splitlines():
        parts = ln.split()
        if len(parts) >= 4:
            modes[parts[3]] = parts[0]
    return modes


def main():
    if len(sys.argv) < 2:
        print('用法: push_api.py "<commit message>"')
        return 1
    message = sys.argv[1]

    remote = api('GET', 'https://api.github.com/repos/%s/commits/main' % REPO)['sha']
    print('remote main:', remote[:12])

    # 远端 commit 由 API 创建，本地对象库可能没有；可用第二个参数指定本地基线
    base = sys.argv[2] if len(sys.argv) > 2 else remote
    diff = subprocess.check_output(
        ['git', 'diff', '--name-status', base, 'HEAD']).decode(errors='replace')
    files, deleted = [], []
    for ln in diff.splitlines():
        parts = ln.split('\t')
        if len(parts) < 2:
            continue
        status, path = parts[0], parts[-1]
        if status.startswith('D'):
            deleted.append(path)
        else:
            files.append(path)
    print('新增/修改:', len(files), '删除:', len(deleted))
    if not files and not deleted:
        print('没有差异，无需推送')
        return 0

    modes = index_modes()
    base_tree = api('GET', 'https://api.github.com/repos/%s/commits/%s'
                    % (REPO, remote))['commit']['tree']['sha']

    entries = []
    for path in files:
        if not os.path.exists(path):
            print('跳过不存在:', path)
            continue
        data = open(path, 'rb').read()
        blob = api('POST', 'https://api.github.com/repos/%s/git/blobs' % REPO,
                   {'content': base64.b64encode(data).decode(), 'encoding': 'base64'})
        gitpath = path.replace('\\', '/')
        mode = modes.get(gitpath, '100644')
        if mode not in ('100644', '100755', '120000'):
            mode = '100644'
        entries.append({'path': gitpath, 'mode': mode, 'type': 'blob', 'sha': blob['sha']})
        print('  blob %s %s (%d B)' % (mode, gitpath, len(data)))

    for path in deleted:
        gitpath = path.replace('\\', '/')
        entries.append({'path': gitpath, 'mode': '100644', 'type': 'blob', 'sha': None})
        print('  del  %s' % gitpath)

    tree = api('POST', 'https://api.github.com/repos/%s/git/trees' % REPO,
               {'base_tree': base_tree, 'tree': entries})
    print('new tree:', tree['sha'][:12])

    commit = api('POST', 'https://api.github.com/repos/%s/git/commits' % REPO,
                 {'message': message, 'tree': tree['sha'], 'parents': [remote]})
    print('new commit:', commit['sha'][:12])

    ref = api('PATCH', 'https://api.github.com/repos/%s/git/refs/heads/main' % REPO,
              {'sha': commit['sha'], 'force': True})
    print('main updated:', ref['object']['sha'][:12])
    return 0


if __name__ == '__main__':
    sys.exit(main())
