#!/bin/bash
set -euo pipefail

echo "== Before =="
df -h /

echo
echo "Removing ChatWeb/CyberKit/Reynard temporary build directories from /private/tmp ..."
find /private/tmp -maxdepth 1 \
  \( -name 'cyberkit-*' -o -name 'CyberKit*' -o -name 'chatweb-*' -o -name 'dualai-*' -o -name 'Reynard*' -o -name 'reynard-*' \) \
  -print -exec rm -rf {} +

echo
echo "Removing Xcode DerivedData ..."
rm -rf "$HOME/Library/Developer/Xcode/DerivedData"

echo
echo "== After =="
df -h /

echo
echo "Kept intentionally:"
echo "  $HOME/Library/Developer/Xcode/iOS DeviceSupport"
echo "  $HOME/Library/Developer/CoreSimulator"
