#!/usr/bin/env python3
import collections
import re
import sys


def main():
    path = sys.argv[1]
    with open(path, encoding="utf-8", errors="replace") as f:
        lines = f.readlines()

    objects = {}
    in_objects = False
    in_symbols = False
    rows = []
    for line in lines:
        if line.startswith("# Object files:"):
            in_objects = True
            continue
        if line.startswith("# Sections:"):
            in_objects = False
        if in_objects:
            m = re.match(r"\[\s*(\d+)\]\s+(.*)$", line.rstrip())
            if m:
                objects[int(m.group(1))] = m.group(2)
            continue
        if line.startswith("# Symbols:"):
            in_symbols = True
            continue
        if line.startswith("# Dead Stripped Symbols:"):
            in_symbols = False
        if not in_symbols or not line.startswith("0x"):
            continue
        sm = re.match(
            r"^(0x[0-9A-Fa-f]+)\t(0x[0-9A-Fa-f]+)\t\[\s*(\d+)\]\s+(.*)$",
            line.rstrip(),
        )
        if not sm:
            continue
        addr = int(sm.group(1), 16)
        size = int(sm.group(2), 16)
        if not size:
            continue
        rows.append((addr, size, int(sm.group(3)), sm.group(4)))

    # Current map's __TEXT,__text range.
    text_start = None
    text_end = None
    for line in lines:
        if "\t__TEXT\t__text" in line:
            p = line.split()
            text_start = int(p[0], 16)
            text_end = text_start + int(p[1], 16)
            break
    if text_start is None:
        raise SystemExit("__TEXT,__text not found")

    by_obj = collections.Counter()
    by_name = collections.Counter()
    for addr, size, idx, name in rows:
        if text_start <= addr < text_end:
            size = min(size, text_end - addr)
            by_obj[idx] += size
            by_name[name] += size

    print(f"__TEXT,__text mapped: {sum(by_obj.values())/1048576:.3f} MiB")
    print("--- top objects ---")
    for idx, size in by_obj.most_common(100):
        print(f"{size/1048576:8.3f} MiB [{idx:4d}] {objects.get(idx, '?')}")

    print("--- SpiderMonkey / JS inputs ---")
    js = [(idx, size, objects.get(idx, '?')) for idx, size in by_obj.items()
          if 'js/src' in objects.get(idx, '') or 'libjs_static.a' in objects.get(idx, '')]
    for idx, size, obj in sorted(js, key=lambda x: x[1], reverse=True):
        print(f"{size/1048576:8.3f} MiB [{idx:4d}] {obj}")
    print(f"JS named-input subtotal: {sum(x[1] for x in js)/1048576:.3f} MiB")


if __name__ == "__main__":
    main()
