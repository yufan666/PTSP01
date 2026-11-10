# -*- coding: utf-8 -*-
# git data API 一次性推送全部差异文件到 yufan666/PTSP01 main
import base64
import json
import ssl
import subprocess
import urllib.request

ssl._create_default_https_context = ssl._create_unverified_context

REPO = 'yufan666/PTSP01'


def api(method, url, body=None, retries=5):
    import time
    token = open('audio-port/token.txt').read().strip()
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
            print(f'  retry {attempt + 1}/{retries} ({method} {url.split("/")[-1]}): {e}')
            time.sleep(6)
    raise RuntimeError(f'API 重试耗尽: {url}')


REMOTE_MAIN = api('GET', f'https://api.github.com/repos/{REPO}/commits/main')['sha']
print('remote main:', REMOTE_MAIN[:12])


# 差异文件列表（含状态）
out = subprocess.check_output(
    ['git', 'diff', '--name-status', REMOTE_MAIN, 'HEAD']).decode()
files = []
for ln in out.splitlines():
    parts = ln.split('\t')
    if len(parts) >= 2:
        files.append(parts[-1])
print('差异文件数:', len(files))

base_tree = api('GET', f'https://api.github.com/repos/{REPO}/commits/{REMOTE_MAIN}'
                )['commit']['tree']['sha']
print('base tree:', base_tree[:12])

entries = []
for path in files:
    data = open(path, 'rb').read()
    blob = api('POST', f'https://api.github.com/repos/{REPO}/git/blobs',
               {'content': base64.b64encode(data).decode(),
                'encoding': 'base64'})
    entries.append({'path': path.replace('\\', '/'), 'mode': '100644',
                    'type': 'blob', 'sha': blob['sha']})
    print('blob ok:', path, len(data))

tree = api('POST', f'https://api.github.com/repos/{REPO}/git/trees', {
    'base_tree': base_tree, 'tree': entries})
print('new tree:', tree['sha'][:12])

commit = api('POST', f'https://api.github.com/repos/{REPO}/git/commits', {
    'message': 'audio: AR9331 I2S + WM8988 移植内核 6.12（耳机孔驱动：内核补丁/DTS/kmod/CI）',
    'tree': tree['sha'], 'parents': [REMOTE_MAIN]})
print('new commit:', commit['sha'][:12])

ref = api('PATCH', f'https://api.github.com/repos/{REPO}/git/refs/heads/main',
          {'sha': commit['sha'], 'force': True})
print('main updated:', ref['object']['sha'][:12])
