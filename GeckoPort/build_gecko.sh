#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${1:-$PROJECT_ROOT/build/firefox-src}"
BUILD_JOBS="${GECKO_BUILD_JOBS:-4}"

[ -x "$SOURCE_DIR/mach" ] || { echo "error: missing mach in $SOURCE_DIR" >&2; exit 1; }
case "$BUILD_JOBS" in
  ""|*[!0-9]*|0) echo "error: GECKO_BUILD_JOBS must be a positive integer" >&2; exit 1 ;;
esac

# MCP command timeouts can leave mach/make/cargo/clang/linker descendants alive.
# Refuse to start another build while any Gecko build stage is still present;
# this prevents multiple stale builds from thrashing swap on the 16 GiB host.
if [ "${GECKO_ALLOW_CONCURRENT_BUILD:-0}" != "1" ]; then
  if pgrep -f "[m]ach build" >/dev/null 2>&1 || \
     pgrep -f "[m]ake -f client.mk" >/dev/null 2>&1 || \
     pgrep -f "[c]argo rustc.*toolkit/library/rust/Cargo.toml" >/dev/null 2>&1 || \
     pgrep -f "[c]lang.*obj-gemini-gecko-ios-arm64" >/dev/null 2>&1 || \
     pgrep -f "[l]d64.lld.*XUL" >/dev/null 2>&1; then
    echo "error: an existing Gecko build process is still running; do not start a duplicate build" >&2
    echo "       set GECKO_ALLOW_CONCURRENT_BUILD=1 only for an intentional concurrent build" >&2
    exit 2
  fi
fi

IOS_SDK_PATH="${IOS_SDK_PATH:-$(xcrun --sdk iphoneos --show-sdk-path)}"
[ -d "$IOS_SDK_PATH" ] || { echo "error: invalid iOS SDK path: $IOS_SDK_PATH" >&2; exit 1; }

"$SCRIPT_DIR/verify_jit_patchset.sh" "$SOURCE_DIR"
rsync -a "$SCRIPT_DIR/mozconfig.ios13-arm64" "$SOURCE_DIR/.mozconfig"
echo "ac_add_options --with-ios-sdk=$IOS_SDK_PATH" >> "$SOURCE_DIR/.mozconfig"

cd "$SOURCE_DIR"
./mach build -j"$BUILD_JOBS"
