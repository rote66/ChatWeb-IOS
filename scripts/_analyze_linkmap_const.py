#!/usr/bin/env python3
import collections
import re
import sys


path = sys.argv[1] if len(sys.argv) > 1 else "build/firefox-src/obj-gemini-gecko-ios-arm64/toolkit/library/build/XUL.linkmap"
only_index = int(sys.argv[2]) if len(sys.argv) > 2 else None

with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = fh.readlines()

objects = {}
in_objects = False
const_start = None
const_end = None
in_symbols = False
totals = collections.Counter()
symbol_rows = collections.defaultdict(list)

for raw in lines:
    line = raw.rstrip("\n")
    if line == "# Object files:":
        in_objects = True
        continue
    if line == "# Sections:":
        in_objects = False
        continue
    if in_objects:
        m = re.match(r"^\[\s*(\d+)\]\s+(.+)$", line)
        if m:
            objects[int(m.group(1))] = m.group(2)
        continue

    if "\t__TEXT\t__const" in line:
        parts = line.split("\t")
        const_start = int(parts[0], 16)
        const_end = const_start + int(parts[1], 16)
        continue

    if line == "# Symbols:":
        in_symbols = True
        continue
    if line == "# Dead Stripped Symbols:":
        in_symbols = False
        continue
    if not in_symbols or const_start is None:
        continue

    m = re.match(r"^(0x[0-9A-Fa-f]+)\t(0x[0-9A-Fa-f]+)\t\[\s*(\d+)\]\s+(.+)$", line)
    if not m:
        continue
    addr = int(m.group(1), 16)
    size = int(m.group(2), 16)
    if not (const_start <= addr < const_end) or size <= 0:
        continue
    idx = int(m.group(3))
    name = m.group(4)
    totals[idx] += size
    symbol_rows[idx].append((size, addr, name))

print(f"__TEXT,__const mapped total: {sum(totals.values())} bytes ({sum(totals.values()) / 1048576:.3f} MiB)")
for idx, total in totals.most_common(60):
    if only_index is not None and idx != only_index:
        continue
    print(f"{total / 1048576:8.3f} MiB [{idx:4d}] {objects.get(idx, '<unknown>')}")
    for size, addr, name in sorted(symbol_rows[idx], reverse=True)[:80 if only_index is not None else 5]:
        print(f"           {size / 1024:8.1f} KiB 0x{addr:x} {name[:170]}")
