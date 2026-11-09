#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DTS 结构自检：属性必须写在子节点之前。

dtc 只在真正编译时才报
    Error: xxx.dts:194.2-195.34 Properties must precede subnodes
    FATAL ERROR: Unable to parse input tree
而 OpenWrt 的 image 阶段发生在整轮编译快结束时，一次踩坑 = 一小时。
这个脚本把它提前到秒级。

用法: python3 dts_lint.py <a.dts> [b.dts ...]
退出码: 0 正常 / 1 有问题
"""
import re
import sys

NAME = r"[A-Za-z0-9_,@\-\.\+]+"
NODE_RE = re.compile(r"^(?:" + NAME + r":\s*)?" + NAME + r"\s*\{\s*$")
PROP_RE = re.compile(r"^[A-Za-z0-9_,@\-\.\+#]+\s*=\s*.+;\s*$")
BOOL_RE = re.compile(r"^[a-z0-9\-]+;\s*$")


def lint(path):
    raw = open(path, encoding="utf-8").read()
    txt = re.sub(r"/\*.*?\*/", "", raw, flags=re.S)
    txt = re.sub(r"//[^\n]*", "", txt)

    stack = []
    bad = []
    for lineno, line in enumerate(txt.split("\n"), 1):
        s = line.strip()
        if not s:
            continue
        if s.startswith("}"):
            if stack:
                stack.pop()
            continue
        if NODE_RE.match(s):
            if stack:
                stack[-1]["seen_sub"] = True
            stack.append({"name": s.rstrip("{").strip(), "line": lineno,
                          "seen_sub": False})
            continue
        if (PROP_RE.match(s) or BOOL_RE.match(s)) and stack and stack[-1]["seen_sub"]:
            bad.append((lineno, s[:50], stack[-1]["name"], stack[-1]["line"]))

    ok = True
    if stack:
        print("!! %s: 括号不平衡，末尾还有 %d 层未闭合（最内层 %s 起始行 %d）"
              % (path, len(stack), stack[-1]["name"], stack[-1]["line"]))
        ok = False
    if bad:
        print("!! %s: 以下属性写在子节点之后（dtc 会 FATAL）：" % path)
        for lineno, text, node, nline in bad:
            print("   行%-5d %-52s 位于节点 %s（起始行 %d）内"
                  % (lineno, text, node, nline))
        ok = False
    if ok:
        print("✓ %s 结构检查通过" % path)
    return ok


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    return 0 if all(lint(p) for p in argv) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
