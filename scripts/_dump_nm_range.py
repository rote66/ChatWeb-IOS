#!/usr/bin/env python3
import re
import subprocess
import sys

path = sys.argv[1]
lo = int(sys.argv[2], 0)
hi = int(sys.argv[3], 0)

text = subprocess.check_output(["nm", "-n", "-C", path], text=True, errors="ignore")
for line in text.splitlines():
    m = re.match(r"^([0-9A-Fa-f]+)\s+([A-Za-z])\s+(.+)$", line)
    if not m:
        continue
    addr = int(m.group(1), 16)
    if lo <= addr < hi and "l_anon." not in m.group(3):
        print(f"0x{addr:x} {m.group(2)} {m.group(3)}")
