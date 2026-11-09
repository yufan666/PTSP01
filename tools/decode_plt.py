#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 pltst3.sh / spitest 的原始输出解码成物理值。

用法：
    python tools/decode_plt.py < 串口输出.txt
    python tools/decode_plt.py "rx(6): 00 1A 2B 3C 4D 5E"

换算公式来自原厂 libpl7223.so 反汇编（pl7223_calcuate_value）：
    value = uint48_be(buf) / (1 << n)
        n = 22  -> 电压  0x3000
        n = 24  -> 电流  0x3006
        n = 24  -> 功率  0x3078
    电量 0x308a / 频率 0x305a 走另外两个函数，见下。
"""
import re
import sys

# 端口 -> reg -> 片选来源（DTS cs-gpios 索引）
PORT = {
    "0.1": "reg1  cs-gpios[1] GPIO26     孔3",
    "0.2": "reg2  cs-gpios[2] GPIO1      孔2",
    "0.3": "reg3  cs-gpios[3] pca9554 P1 孔1",
}

FIELDS = [
    # (标签关键字, 字节数, 除数 2^n, 单位)
    ("电压", 6, 22, "V"),
    ("电流", 6, 24, "A"),
    ("功率", 6, 24, "W"),
    ("电量", 6, 24, "kWh?"),
    ("频率", 2, 0, "Hz?"),
]


def u48(bs):
    v = 0
    for b in bs:
        v = (v << 8) | b
    return v


def scan(text):
    dev = None
    out = []
    for line in text.splitlines():
        m = re.search(r"/dev/spidev(\d+\.\d+)", line)
        if m:
            dev = m.group(1)
            out.append("\n=== spidev%s   %s" % (dev, PORT.get(dev, "")))
            continue
        m = re.search(r"(存在性|开关|电压|电流|功率|电量|频率).*?rx\((\d+)\):(.*)$", line)
        if not m:
            m2 = re.search(r"^\s*(存在性 0x3860|开关\s+0x380f|电压.*|电流.*|功率.*|电量.*|频率.*)\s*:\s*rx\((\d+)\):(.*)$", line)
            if not m2:
                continue
            m = m2
        label = m.group(1).strip()
        n = int(m.group(2))
        raw = [int(x, 16) for x in re.findall(r"[0-9A-Fa-f]{2}", m.group(3))]
        if not raw:
            out.append("  %-18s (空)" % label)
            continue
        hexs = " ".join("%02X" % b for b in raw)
        extra = ""
        if "存在性" in label:
            extra = "→ %s" % ("✓ 检测到 PL7223" if raw[0] == 0x04 else "✗ 期望 0x04")
        elif "开关" in label:
            extra = "→ 0b%s" % format(raw[0], "08b")
        else:
            for key, nb, shift, unit in FIELDS:
                if key in label and len(raw) >= nb:
                    v = u48(raw[:nb])
                    val = v / float(1 << shift) if shift else v
                    extra = "→ %d / 2^%d = %.4f %s" % (v, shift, val, unit)
                    break
        out.append("  %-18s rx(%d): %-20s %s" % (label, n, hexs, extra))
    return "\n".join(out)


if __name__ == "__main__":
    data = sys.stdin.read() if len(sys.argv) < 2 else " ".join(sys.argv[1:])
    print(scan(data))
