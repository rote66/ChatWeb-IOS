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

manifest_value() {
    local key="$1"
    local manifest="$2"
    /usr/bin/sed -n "s/^${key}=//p" "$manifest" | /usr/bin/head -n 1
}

verify_tree() {
    local runtime="$1"
    local include="$2"
    local manifest="$3"
    local expected_sha expected_bytes expected_files actual_sha actual_bytes actual_files

    [ -f "$manifest" ] || return 1
    [ -f "$runtime/XUL" ] || return 1
    [ -f "$runtime/omni.ja" ] || return 1
    [ -f "$include/GeckoView/GeckoViewSwiftSupport.h" ] || return 1
    [ -f "$include/GeckoView/IOSBootstrap.h" ] || return 1
    [ -f "$include/GeckoView/GeckoViewRuntimeSupport.h" ] || return 1
    /usr/bin/lipo "$runtime/XUL" -verify_arch arm64 >/dev/null 2>&1 || return 1

    expected_sha="$(manifest_value XUL_SHA256 "$manifest")"
    expected_bytes="$(manifest_value XUL_BYTES "$manifest")"
    expected_files="$(manifest_value RUNTIME_FILES "$manifest")"
    [ -n "$expected_sha" ] || return 1
    [ -n "$expected_bytes" ] || return 1
    [ -n "$expected_files" ] || return 1

    actual_sha="$(/usr/bin/shasum -a 256 "$runtime/XUL" | /usr/bin/awk '{print $1}')"
    actual_bytes="$(/usr/bin/stat -f '%z' "$runtime/XUL")"
    actual_files="$(/usr/bin/find "$runtime" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"
    [ "$actual_sha" = "$expected_sha" ] || return 1
    [ "$actual_bytes" = "$expected_bytes" ] || return 1
    [ "$actual_files" = "$expected_files" ] || return 1
    return 0
}

[ -f "$MANIFEST" ] || fail "missing prebuilt Gecko manifest: $MANIFEST"

if verify_tree "$RUNTIME_DIR" "$INCLUDE_DIR" "$MANIFEST"; then
    echo "Using expanded prebuilt Gecko core: $PREBUILT_DIR"
    exit 0
fi

[ -f "$ARCHIVE" ] || fail "missing prebuilt Gecko archive: $ARCHIVE"

WORK_DIR="$PREBUILT_DIR/.extract.$$"
trap '/bin/rm -rf "$WORK_DIR"' EXIT
/bin/rm -rf "$WORK_DIR"
/bin/mkdir -p "$WORK_DIR"
/usr/bin/unzip -q "$ARCHIVE" -d "$WORK_DIR"

[ -f "$WORK_DIR/MANIFEST.lock" ] || fail "archive has no embedded manifest"
/usr/bin/cmp -s "$WORK_DIR/MANIFEST.lock" "$MANIFEST" || \
    fail "embedded prebuilt manifest does not match GeckoPrebuilt/MANIFEST.lock"
verify_tree "$WORK_DIR/Runtime" "$WORK_DIR/include" "$WORK_DIR/MANIFEST.lock" || \
    fail "archive runtime does not match its manifest or arm64 header contract"

/bin/rm -rf "$RUNTIME_DIR" "$INCLUDE_DIR"
/bin/mv "$WORK_DIR/Runtime" "$RUNTIME_DIR"
/bin/mv "$WORK_DIR/include" "$INCLUDE_DIR"

trap - EXIT
/bin/rm -rf "$WORK_DIR"

echo "Prepared prebuilt Gecko core: $PREBUILT_DIR"
