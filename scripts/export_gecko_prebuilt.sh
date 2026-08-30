#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${GECKO_SOURCE_DIR:-$PROJECT_ROOT/build/firefox-src}"
OBJ_DIR="${GECKO_OBJ_DIR:-$SOURCE_DIR/obj-gemini-gecko-ios-arm64}"
STAGE_DIR="${GECKO_STAGE_DIR:-$PROJECT_ROOT/build/GeckoRuntimeClean}"
PREBUILT_DIR="${GECKO_PREBUILT_DIR:-$PROJECT_ROOT/GeckoPrebuilt}"
ARCHIVE="$PREBUILT_DIR/GeckoCore-ios-arm64.zip"
MANIFEST="$PREBUILT_DIR/MANIFEST.lock"
LOCK_FILE="$PROJECT_ROOT/GeckoPort/PATCHSET.lock"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -d "$SOURCE_DIR/.git" ] || fail "missing Firefox source checkout: $SOURCE_DIR"
[ -d "$OBJ_DIR" ] || fail "missing Gecko objdir: $OBJ_DIR"
[ -f "$LOCK_FILE" ] || fail "missing Gecko source lock: $LOCK_FILE"

if [ "${GECKO_SKIP_STAGE:-0}" != "1" ]; then
    GECKO_SOURCE_DIR="$SOURCE_DIR" GECKO_OBJ_DIR="$OBJ_DIR" \
        bash "$PROJECT_ROOT/scripts/stage_gecko_runtime.sh" "$STAGE_DIR"
fi

[ -f "$STAGE_DIR/XUL" ] || fail "staged runtime missing XUL: $STAGE_DIR/XUL"

HEADER_ROOT="$OBJ_DIR/dist/include/GeckoView"
for header in GeckoViewSwiftSupport.h IOSBootstrap.h GeckoViewRuntimeSupport.h; do
    [ -f "$HEADER_ROOT/$header" ] || fail "missing exported Gecko header: $header"
done

FIREFOX_COMMIT="$(sed -n 's/^FIREFOX_COMMIT=//p' "$LOCK_FILE" | head -n 1)"
FIREFOX_TAG="$(sed -n 's/^FIREFOX_TAG=//p' "$LOCK_FILE" | head -n 1)"
[ -n "$FIREFOX_COMMIT" ] || fail "FIREFOX_COMMIT missing from PATCHSET.lock"

WORK_DIR="$PREBUILT_DIR/.export.$$"
ARCHIVE_TMP="$PREBUILT_DIR/GeckoCore-ios-arm64.zip.tmp"
trap '/bin/rm -rf "$WORK_DIR" "$ARCHIVE_TMP"' EXIT
/bin/rm -rf "$WORK_DIR" "$ARCHIVE_TMP"
/bin/mkdir -p "$WORK_DIR/Runtime" "$WORK_DIR/include/GeckoView" "$PREBUILT_DIR"

/usr/bin/rsync -a --delete "$STAGE_DIR/" "$WORK_DIR/Runtime/"
for header in GeckoViewSwiftSupport.h IOSBootstrap.h GeckoViewRuntimeSupport.h; do
    /bin/cp -f "$HEADER_ROOT/$header" "$WORK_DIR/include/GeckoView/$header"
done

XUL_SHA256="$(/usr/bin/shasum -a 256 "$WORK_DIR/Runtime/XUL" | /usr/bin/awk '{print $1}')"
XUL_BYTES="$(/usr/bin/stat -f '%z' "$WORK_DIR/Runtime/XUL")"
RUNTIME_FILES="$(/usr/bin/find "$WORK_DIR/Runtime" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

/bin/cat > "$WORK_DIR/MANIFEST.lock" <<EOF
# ChatWeb prebuilt Gecko core
FIREFOX_TAG=$FIREFOX_TAG
FIREFOX_COMMIT=$FIREFOX_COMMIT
TARGET=aarch64-apple-ios
MIN_IOS=13.0
CONFIGURATION=Release
XUL_SHA256=$XUL_SHA256
XUL_BYTES=$XUL_BYTES
RUNTIME_FILES=$RUNTIME_FILES
EOF

(
    cd "$WORK_DIR"
    COPYFILE_DISABLE=1 /usr/bin/zip -9qryX -D "$ARCHIVE_TMP" Runtime include MANIFEST.lock
)

[ -f "$ARCHIVE_TMP" ] || fail "failed to create prebuilt archive"

/bin/rm -rf "$PREBUILT_DIR/Runtime" "$PREBUILT_DIR/include"
/bin/mv "$WORK_DIR/Runtime" "$PREBUILT_DIR/Runtime"
/bin/mv "$WORK_DIR/include" "$PREBUILT_DIR/include"
/bin/cp -f "$WORK_DIR/MANIFEST.lock" "$MANIFEST"
/bin/mv "$ARCHIVE_TMP" "$ARCHIVE"

ARCHIVE_BYTES="$(/usr/bin/stat -f '%z' "$ARCHIVE")"
if [ "$ARCHIVE_BYTES" -ge 100000000 ]; then
    fail "prebuilt archive is ${ARCHIVE_BYTES} bytes; keep it below GitHub's 100 MB file limit"
fi

trap - EXIT
/bin/rm -rf "$WORK_DIR"

echo "Exported Gecko prebuilt runtime: $PREBUILT_DIR/Runtime"
echo "Exported Gecko prebuilt headers: $PREBUILT_DIR/include"
echo "Created prebuilt archive: $ARCHIVE ($ARCHIVE_BYTES bytes)"
