#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PREBUILT_DIR="${GECKO_PREBUILT_DIR:-$PROJECT_ROOT/GeckoPrebuilt}"
ARCHIVE="${GECKO_PREBUILT_ARCHIVE:-$PREBUILT_DIR/GeckoCore-ios-arm64.zip}"
RUNTIME_DIR="$PREBUILT_DIR/Runtime"
INCLUDE_DIR="$PREBUILT_DIR/include"
MANIFEST="$PREBUILT_DIR/MANIFEST.lock"

fail() {
    echo "error: $*" >&2
    exit 1
}

verify_tree() {
    local runtime="$1"
    local include="$2"

    [ -f "$runtime/XUL" ] || return 1
    [ -f "$include/GeckoView/GeckoViewSwiftSupport.h" ] || return 1
    [ -f "$include/GeckoView/IOSBootstrap.h" ] || return 1
    [ -f "$include/GeckoView/GeckoViewRuntimeSupport.h" ] || return 1
    /usr/bin/lipo "$runtime/XUL" -verify_arch arm64 >/dev/null 2>&1 || return 1
    return 0
}

if verify_tree "$RUNTIME_DIR" "$INCLUDE_DIR"; then
    echo "Using expanded prebuilt Gecko core: $PREBUILT_DIR"
    exit 0
fi

[ -f "$ARCHIVE" ] || fail "missing prebuilt Gecko archive: $ARCHIVE"
[ -f "$MANIFEST" ] || fail "missing prebuilt Gecko manifest: $MANIFEST"

WORK_DIR="$PREBUILT_DIR/.extract.$$"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
/bin/rm -rf "$WORK_DIR"
/bin/mkdir -p "$WORK_DIR"
/usr/bin/unzip -q "$ARCHIVE" -d "$WORK_DIR"

verify_tree "$WORK_DIR/Runtime" "$WORK_DIR/include" || \
    fail "archive does not contain a valid arm64 Gecko runtime/header set"

if [ -f "$WORK_DIR/MANIFEST.lock" ]; then
    /usr/bin/cmp -s "$WORK_DIR/MANIFEST.lock" "$MANIFEST" || \
        fail "embedded prebuilt manifest does not match GeckoPrebuilt/MANIFEST.lock"
fi

/bin/rm -rf "$RUNTIME_DIR" "$INCLUDE_DIR"
/bin/mv "$WORK_DIR/Runtime" "$RUNTIME_DIR"
/bin/mv "$WORK_DIR/include" "$INCLUDE_DIR"

trap - EXIT
/bin/rm -rf "$WORK_DIR"

echo "Prepared prebuilt Gecko core: $PREBUILT_DIR"
