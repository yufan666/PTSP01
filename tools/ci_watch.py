#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""查看 PTSP01 最近的 Actions run / 各 step 状态 / 某 step 的日志尾部。

用法：
    python tools/ci_watch.py runs            # 最近 5 次 run 概览
    python tools/ci_watch.py steps [run_id]  # 某次 run 的 job + step 详情
    python tools/ci_watch.py log <job_id> [tail行数]
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

REPO = "yufan666/PTSP01"
API = "https://api.github.com/repos/" + REPO
TOK = os.environ.get("GHTOK") or ""


def call(path, raw=False, retries=3):
    for i in range(retries):
        req = urllib.request.Request(API + path)
        req.add_header("Authorization", "Bearer " + TOK)
        req.add_header("Accept", "application/vnd.github+json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read()
            return data.decode(errors="replace") if raw else json.loads(data.decode())
        except urllib.error.HTTPError as e:
            if e.code in (404, 403) and i == retries - 1:
                sys.exit("HTTP %s %s" % (e.code, path))
            if i == retries - 1:
                sys.exit("HTTP %s %s: %s" % (e.code, path, e.read().decode()[:400]))
            time.sleep(3)


def cmd_runs():
    d = call("/actions/runs?per_page=5")
    for r in d["workflow_runs"]:
        print("%-11s %-9s %-8s %s  %s" % (
            r["id"], r["status"], r["conclusion"] or "-",
            r["created_at"].replace("T", " ")[5:19], r["head_sha"][:7]))
        print("            %s" % r["html_url"])


def cmd_steps(run_id=None):
    if not run_id:
        run_id = call("/actions/runs?per_page=1")["workflow_runs"][0]["id"]
    d = call("/actions/runs/%s/jobs" % run_id)
    print("run", run_id, "->", d["total_count"], "job(s)")
    for j in d["jobs"]:
        print("\nJOB %s  %-9s %-8s  job_id=%s" % (j["name"], j["status"], j["conclusion"] or "-", j["id"]))
        if j.get("started_at"):
            print("      started %s" % j["started_at"].replace("T", " ")[:19])
        for s in j["steps"]:
            print("   %-9s %-8s  %s" % (s["status"], s["conclusion"] or "-", s["name"]))
    return run_id


def cmd_log(job_id, tail=120):
    txt = call("/actions/jobs/%s/logs" % job_id, raw=True)
    lines = txt.splitlines()
    print("=== 共 %d 行，尾部 %d 行 ===" % (len(lines), tail))
    print("\n".join(lines[-int(tail):]))


if __name__ == "__main__":
    if not TOK:
        sys.exit("请先 export GHTOK=...")
    a = sys.argv[1:]
    if not a or a[0] == "runs":
        cmd_runs()
    elif a[0] == "steps":
        cmd_steps(a[1] if len(a) > 1 else None)
    elif a[0] == "log":
        cmd_log(a[1], a[2] if len(a) > 2 else 120)
    else:
        sys.exit(__doc__)
