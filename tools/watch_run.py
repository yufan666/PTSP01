#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""watch_run.py —— 盯一次 Actions run 到结束；失败时自动拉 job 日志并提取错误

用法：
    python tools/watch_run.py <run_id> [轮询间隔秒]

token 现场从 Windows 凭据管理器取（git credential fill），不落盘。
"""
import json
import os
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.request

ssl._create_default_https_context = ssl._create_unverified_context
REPO = 'yufan666/PTSP01'
API = 'https://api.github.com/repos/' + REPO


def token():
    out = subprocess.run(
        ['git', 'credential', 'fill'],
        input='protocol=https\nhost=github.com\n\n',
        capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith('password='):
            return line.split('=', 1)[1].strip()
    raise SystemExit('凭据管理器里没取到 github 令牌')


TOK = token()


def api(path, raw=False, no_redirect=False):
    url = path if path.startswith('http') else API + path
    req = urllib.request.Request(url)
    req.add_header('Authorization', 'Bearer ' + TOK)
    req.add_header('Accept', 'application/vnd.github+json')
    req.add_header('User-Agent', 'watch_run')
    if not no_redirect:
        with urllib.request.urlopen(req, timeout=90) as r:
            data = r.read()
        return data if raw else json.loads(data.decode())

    class NR(urllib.request.HTTPRedirectHandler):
        def redirect_request(self, *a, **k):
            return None

    opener = urllib.request.build_opener(NR)
    try:
        with opener.open(req, timeout=90) as r:
            return r.read()
    except urllib.error.HTTPError as e:
        loc = e.headers.get('Location')
        if not loc:
            raise
        # 签名 URL 不能带 Authorization，否则 Azure 报 401
        with urllib.request.urlopen(loc, timeout=180) as r:
            return r.read()


def job_log(job_id):
    data = api('/actions/jobs/%d/logs' % job_id, raw=True, no_redirect=True)
    return data.decode('utf-8', 'replace')


def strip_ts(text):
    out = []
    for ln in text.splitlines():
        parts = ln.split(' ', 1)
        if len(parts) == 2 and parts[0][:2] == '20' and 'T' in parts[0]:
            out.append(parts[1])
        else:
            out.append(ln)
    return '\n'.join(out)


def main():
    run_id = int(sys.argv[1])
    gap = int(sys.argv[2]) if len(sys.argv) > 2 else 120
    deadline = time.time() + 4 * 3600
    last = None

    while time.time() < deadline:
        d = api('/actions/runs/%d' % run_id)
        st, cc = d['status'], d['conclusion']
        if (st, cc) != last:
            print('[%s] %s %s' % (time.strftime('%H:%M:%S'), st, cc), flush=True)
            last = (st, cc)
        if st == 'completed':
            break
        time.sleep(gap)

    d = api('/actions/runs/%d' % run_id)
    print('=' * 60)
    print('RUN %d -> %s %s' % (run_id, d['status'], d['conclusion']), flush=True)
    if d['status'] != 'completed':
        print('超时未结束，仍在 %s' % d['status'])
        return 0

    if d['conclusion'] == 'success':
        arts = api('/actions/runs/%d/artifacts' % run_id).get('artifacts', [])
        print('产物：')
        for a in arts:
            print('  %-40s %8.1f KB' % (a['name'], a['size_in_bytes'] / 1024.0))
        return 0

    jobs = api('/actions/runs/%d/jobs' % run_id)['jobs']
    for j in jobs:
        bad = [s for s in j['steps'] if s.get('conclusion') == 'failure']
        print('失败步骤：', ', '.join('%s(%s)' % (s['number'], s['name']) for s in bad) or '-')
        log = strip_ts(job_log(j['id']))
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            '..', '..', 'run_%d.log' % run_id)
        path = os.path.normpath(path)
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(log)
        print('日志已存:', path, '(%d 行)' % len(log.splitlines()))
        print('-' * 60)
        # 优先打印 workflow 自带的诊断 group
        idx = log.find('##[group]构建失败，日志尾部')
        if idx >= 0:
            print(log[idx:idx + 6000])
        else:
            print('\n'.join(log.splitlines()[-150:]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
