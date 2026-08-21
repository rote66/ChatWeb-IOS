#!/usr/bin/env python3
import re
import subprocess
import sys


path = sys.argv[1] if len(sys.argv) > 1 else "build/firefox-src/obj-gemini-gecko-ios-arm64/dist/bin/XUL"

otool = subprocess.check_output(["xcrun", "otool", "-l", path], text=True, errors="ignore")
lines = otool.splitlines()
const_addr = None
const_size = None
for i, line in enumerate(lines):
    if line.strip() != "sectname __const":
        continue
    block = "\n".join(lines[i : i + 8])
    if "segname __TEXT" not in block:
        continue
    m_addr = re.search(r"^\s*addr\s+(0x[0-9a-fA-F]+)", block, re.M)
    m_size = re.search(r"^\s*size\s+(0x[0-9a-fA-F]+)", block, re.M)
    if m_addr and m_size:
        const_addr = int(m_addr.group(1), 16)
        const_size = int(m_size.group(1), 16)
        break

if const_addr is None or const_size is None:
    raise SystemExit("could not locate __TEXT,__const")

const_end = const_addr + const_size
nm = subprocess.check_output(["xcrun", "nm", "-n", "-C", path], text=True, errors="ignore")
symbols = []
for line in nm.splitlines():
    m = re.match(r"^([0-9a-fA-F]+)\s+([A-Za-z])\s+(.+)$", line)
    if not m:
        continue
    addr = int(m.group(1), 16)
    if const_addr <= addr < const_end:
        symbols.append((addr, m.group(3)))

rows = []
for i, (addr, name) in enumerate(symbols):
    next_addr = symbols[i + 1][0] if i + 1 < len(symbols) else const_end
    next_name = symbols[i + 1][1] if i + 1 < len(symbols) else "<section-end>"
    gap = next_addr - addr
    if gap > 0:
        rows.append((gap, addr, name, next_name))

print(f"__TEXT,__const addr=0x{const_addr:x} size={const_size} ({const_size / 1048576:.3f} MiB)")
print(f"symbols={len(symbols)}")
for gap, addr, name, next_name in sorted(rows, reverse=True)[:120]:
    print(f"{gap / 1024:9.1f} KiB 0x{addr:x} {name[:180]}")
    print(f"             -> {next_name[:180]}")
