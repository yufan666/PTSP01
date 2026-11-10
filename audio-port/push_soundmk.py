# -*- coding: utf-8 -*-
# 通过 git data API 把 kmod-sound-soc-ath79 的 sound.mk 改动提交到 v25.12.0 tag 链上
import base64
import json
import sys
import ssl
import urllib.request

ssl._create_default_https_context = ssl._create_unverified_context

REPO = 'yufan666/openwrt'
TAG_COMMIT = '4da53efc2fe744601e6189492dbd06b8930d72b8'  # v25.12.0 tag 指向的 commit
PATH = 'package/kernel/linux/modules/sound.mk'


def api(method, url, body=None):
    token = open('audio-port/token.txt').read().strip()
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None)
    req.add_header('Authorization', 'Bearer ' + token)
    req.add_header('Accept', 'application/vnd.github+json')
    req.add_header('User-Agent', 'check')
    with urllib.request.urlopen(req, timeout=40) as r:
        return json.loads(r.read().decode())


content = open('audio-port/ref/sound.mk.new', 'rb').read()
blob = api('POST', f'https://api.github.com/repos/{REPO}/git/blobs',
           {'content': base64.b64encode(content).decode(), 'encoding': 'base64'})
print('blob:', blob['sha'][:12])

base_tree = api('GET', f'https://api.github.com/repos/{REPO}/commits/{TAG_COMMIT}')['commit']['tree']['sha']
print('base tree:', base_tree[:12])

tree = api('POST', f'https://api.github.com/repos/{REPO}/git/trees', {
    'base_tree': base_tree,
    'tree': [{'path': PATH, 'mode': '100644', 'type': 'blob', 'sha': blob['sha']}],
})
print('new tree:', tree['sha'][:12])

commit = api('POST', f'https://api.github.com/repos/{REPO}/git/commits', {
    'message': 'sound: add kmod-sound-soc-ath79 (AR9331 I2S + MBOX DMA, wm8988, simple-card)',
    'tree': tree['sha'],
    'parents': [TAG_COMMIT],
})
print('new commit:', commit['sha'][:12])

ref = api('PATCH', f'https://api.github.com/repos/{REPO}/git/refs/tags/v25.12.0',
          {'sha': commit['sha'], 'force': True})
print('tag moved:', ref['object']['sha'][:12])
