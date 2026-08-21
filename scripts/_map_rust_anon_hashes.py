#!/usr/bin/env python3
import glob
import os
import re
import subprocess
import sys


root = sys.argv[1] if len(sys.argv) > 1 else "build/firefox-src/obj-gemini-gecko-ios-arm64/aarch64-apple-ios/release/deps"
patterns = sys.argv[2:] or [
    "libencoding_rs*.rlib",
    "libicu_*_data*.rlib",
    "libunic_langid_impl*.rlib",
]

for pattern in patterns:
    for path in sorted(glob.glob(os.path.join(root, pattern))):
        proc = subprocess.run(["xcrun", "nm", "-a", path], text=True, errors="ignore", capture_output=True)
        hashes = sorted(set(re.findall(r"l_anon\.([0-9a-f]{16,32})", proc.stdout)))
        print(f"{os.path.getsize(path) / 1048576:8.3f} MiB {os.path.basename(path)}")
        print("  anon_hashes:", " ".join(hashes[:80]) if hashes else "<none>")
