#!/usr/bin/env python3
import collections
import bisect
import re
import subprocess

linkmap = "build/firefox-src/obj-gemini-gecko-ios-arm64/toolkit/library/build/XUL.linkmap"
xul = "build/firefox-src/obj-gemini-gecko-ios-arm64/dist/bin/XUL"
target_index = 1775

rows = []
in_symbols = False
with open(linkmap, "r", encoding="utf-8", errors="replace") as fh:
    for raw in fh:
        line = raw.rstrip("\n")
        if line == "# Symbols:":
            in_symbols = True
            continue
        if line == "# Dead Stripped Symbols:":
            break
        if not in_symbols:
            continue
        m = re.match(
            r"^(0x[0-9A-Fa-f]+)\t(0x[0-9A-Fa-f]+)\t\[\s*(\d+)\]\s+(.+)$",
            line,
        )
        if not m or int(m.group(3)) != target_index:
            continue
        rows.append((int(m.group(1), 16), int(m.group(2), 16), m.group(4)))

groups = collections.defaultdict(list)
for addr, size, name in rows:
    m = re.match(r"l_anon\.([0-9a-f]+)\.\d+$", name)
    if m:
        groups[m.group(1)].append((addr, size, name))

nm_text = subprocess.check_output(["nm", "-n", "-C", xul], text=True, errors="ignore")
nm_rows = []
for line in nm_text.splitlines():
    m = re.match(r"^([0-9A-Fa-f]+)\s+[A-Za-z]\s+(.+)$", line)
    if m:
        nm_rows.append((int(m.group(1), 16), m.group(2)))

nm_addrs = [addr for addr, _ in nm_rows]


def nearest_named(addr):
    i = bisect.bisect_left(nm_addrs, addr)
    out = []
    for j in range(max(0, i - 8), min(len(nm_rows), i + 9)):
        a, name = nm_rows[j]
        if "l_anon." in name:
            continue
        out.append((abs(a - addr), a, name))
    return sorted(out)[:4]

ranked = sorted(groups.items(), key=lambda kv: sum(x[1] for x in kv[1]), reverse=True)
for h, items in ranked[:15]:
    total = sum(x[1] for x in items)
    lo = min(x[0] for x in items)
    hi = max(x[0] + x[1] for x in items)
    print(f"{total / 1048576:7.3f} MiB  {h}  n={len(items)}  0x{lo:x}-0x{hi:x}")
    for addr, size, name in sorted(items, key=lambda x: x[1], reverse=True)[:5]:
        print(f"    anon {size / 1024:7.1f} KiB 0x{addr:x} {name}")
        for delta, a, nearby_name in nearest_named(addr):
            print(f"      near {delta / 1024:7.1f} KiB 0x{a:x} {nearby_name[:150]}")
    nearby = [
        (addr, name)
        for addr, name in nm_rows
        if lo - 32768 <= addr <= hi + 32768 and "l_anon." not in name
    ]
    for addr, name in nearby[:12]:
        print(f"    0x{addr:x} {name[:180]}")
    print()

