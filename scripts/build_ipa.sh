#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$PROJECT_ROOT/DualAI.xcodeproj"
DERIVED_DATA="${DERIVED_DATA:-$PROJECT_ROOT/build/DerivedDataIPA}"
PRODUCT_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/DualAI.app"
DIST_DIR="$PROJECT_ROOT/dist"
IPA_PATH="$DIST_DIR/DualAI.ipa"
DEVELOPER_PATH="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEBUILD="$DEVELOPER_PATH/usr/bin/xcodebuild"
STRIP_TOOL="$DEVELOPER_PATH/Toolchains/XcodeDefault.xctoolchain/usr/bin/strip"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -d "$PROJECT_PATH" ] || fail "missing project: $PROJECT_PATH"
[ -x "$XCODEBUILD" ] || fail "missing xcodebuild: $XCODEBUILD"
[ -x "$STRIP_TOOL" ] || fail "missing strip tool: $STRIP_TOOL"
mkdir -p "$DIST_DIR"

# DualAI intentionally publishes exactly one IPA artifact. Remove stale or
# diagnostic IPA names before every package pass so dist/ never accumulates
# multiple install candidates.
/usr/bin/find "$DIST_DIR" -maxdepth 1 -type f -name '*.ipa' ! -path "$IPA_PATH" -delete

# Do not run `xcodebuild clean` here. XUL is an external linker input under
# the project workspace and Xcode may delete it while cleaning the app target.
# Removing only this script's DerivedData gives us a fully fresh app build
# without touching Gecko's independently-built objdir.
/bin/rm -rf "$DERIVED_DATA"
/bin/mkdir -p "$DERIVED_DATA"

# Fast path: app builds consume the checked-in compressed prebuilt Gecko core.
# This intentionally avoids touching Firefox source/objdir and avoids the
# multi-minute Gecko link. The expanded Runtime/include trees are cached and
# ignored by Git; prepare_gecko_prebuilt.sh extracts them on first use.
bash "$PROJECT_ROOT/scripts/prepare_gecko_prebuilt.sh"

DEVELOPER_DIR="$DEVELOPER_PATH" "$XCODEBUILD" \
    -quiet \
    -project "$PROJECT_PATH" \
    -scheme DualAI \
    -configuration Release \
    -sdk iphoneos \
    -destination "generic/platform=iOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=YES \
    build

[ -d "$PRODUCT_APP" ] || fail "missing build product: $PRODUCT_APP"
[ -f "$PRODUCT_APP/Info.plist" ] || fail "missing built Info.plist"
[ -x "$PRODUCT_APP/DualAI" ] || fail "missing app executable"
/usr/bin/plutil -lint "$PRODUCT_APP/Info.plist" >/dev/null
/usr/bin/lipo "$PRODUCT_APP/DualAI" -verify_arch arm64 || fail "executable is not arm64"

PACKAGE_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatweb-ipa.XXXXXX")"
trap '/bin/rm -rf "$PACKAGE_ROOT"' EXIT
/bin/mkdir -p "$PACKAGE_ROOT/Payload"
/usr/bin/ditto "$PRODUCT_APP" "$PACKAGE_ROOT/Payload/DualAI.app"

STAGED_APP="$PACKAGE_ROOT/Payload/DualAI.app"
[ ! -e "$STAGED_APP/embedded.mobileprovision" ] || fail "embedded provisioning profile must not be packaged"

strip_and_sign_embedded_macho() {
    local root="$1"
    local candidate
    while IFS= read -r -d '' candidate; do
        if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
            # Gecko's objdir artifacts intentionally retain DWARF/local symbols
            # for development and crash symbolication. Strip only the staged
            # IPA copy, preserving the original XUL/dylibs in the objdir.
            # Keep dyld's export/bind metadata but remove the legacy nlist
            # symbol table/string table as documented by Apple strip(1).
            "$STRIP_TOOL" -S -x -N "$candidate"
            # iOS arm64 uses 16 KiB VM pages. Matching that size here keeps
            # the ad-hoc CodeDirectory much smaller than codesign's 4 KiB
            # default (especially for XUL) without changing executable code.
            /usr/bin/codesign --force --sign - --timestamp=none \
                --pagesize 16384 "$candidate"
        fi
    done < <(/usr/bin/find "$root" -type f -print0)
}

verify_embedded_macho() {
    local root="$1"
    local candidate
    while IFS= read -r -d '' candidate; do
        if /usr/bin/file -b "$candidate" | /usr/bin/grep -q 'Mach-O'; then
            /usr/bin/codesign --verify --strict "$candidate"
        fi
    done < <(/usr/bin/find "$root" -type f -print0)
}

if [ -d "$STAGED_APP/Frameworks" ]; then
    strip_and_sign_embedded_macho "$STAGED_APP/Frameworks"
fi

# The app has already been fully linked. Trim debug/local symbols plus the
# legacy nlist table from the staged executable before its final signature.
"$STRIP_TOOL" -S -x -N "$STAGED_APP/DualAI"

# TrollStore's sandboxed-app JIT path uses the ordinary development
# get-task-allow entitlement. Keep this temporary and do not add browser-engine,
# allow-jit, platform-application, or com.apple.private.* entitlements.
APP_ENTITLEMENTS="$PACKAGE_ROOT/DualAI.entitlements"
/bin/cat > "$APP_ENTITLEMENTS" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>get-task-allow</key>
    <true/>
</dict>
</plist>
EOF
/usr/bin/plutil -lint "$APP_ENTITLEMENTS" >/dev/null

/usr/bin/codesign --force --sign - --timestamp=none --pagesize 16384 \
    --generate-entitlement-der \
    --entitlements "$APP_ENTITLEMENTS" "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
if [ -d "$STAGED_APP/Frameworks" ]; then
    verify_embedded_macho "$STAGED_APP/Frameworks"
fi

SIGNED_ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$STAGED_APP" 2>/dev/null || true)"
echo "$SIGNED_ENTITLEMENTS" | /usr/bin/grep -q '<key>get-task-allow</key>' \
    || fail "signed app is missing get-task-allow"
if echo "$SIGNED_ENTITLEMENTS" | /usr/bin/grep -E -q 'com\.apple\.private|platform-application|dynamic-codesigning|allow-jit'; then
    fail "private/restricted entitlement unexpectedly present"
fi

/bin/rm -f "$IPA_PATH"
(
    cd "$PACKAGE_ROOT"
    /usr/bin/zip -9qryX -D "$IPA_PATH" Payload
)

IPA_BYTES="$(/usr/bin/stat -f '%z' "$IPA_PATH")"
MAX_IPA_MIB="${MAX_IPA_MIB:-50}"
case "$MAX_IPA_MIB" in
    ""|*[!0-9]*|0) fail "MAX_IPA_MIB must be a positive integer" ;;
esac
MAX_IPA_BYTES=$((MAX_IPA_MIB * 1024 * 1024))
if [ "$IPA_BYTES" -gt "$MAX_IPA_BYTES" ]; then
    fail "IPA size regression: ${IPA_BYTES} bytes exceeds ${MAX_IPA_MIB} MiB (${MAX_IPA_BYTES} bytes)"
fi
echo "IPA size: $IPA_BYTES bytes (limit: $MAX_IPA_BYTES)"

VERIFY_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatweb-verify.XXXXXX")"
trap '/bin/rm -rf "$PACKAGE_ROOT" "$VERIFY_ROOT"' EXIT
/usr/bin/unzip -q "$IPA_PATH" -d "$VERIFY_ROOT"
[ -d "$VERIFY_ROOT/Payload/DualAI.app" ] || fail "IPA does not contain Payload/DualAI.app"
[ -f "$VERIFY_ROOT/Payload/DualAI.app/Info.plist" ] || fail "IPA app has no Info.plist"
[ -x "$VERIFY_ROOT/Payload/DualAI.app/DualAI" ] || fail "IPA app has no executable"
/usr/bin/plutil -lint "$VERIFY_ROOT/Payload/DualAI.app/Info.plist" >/dev/null
/usr/bin/lipo "$VERIFY_ROOT/Payload/DualAI.app/DualAI" -verify_arch arm64 || fail "packaged executable is not arm64"
/usr/bin/codesign --verify --strict "$VERIFY_ROOT/Payload/DualAI.app"
if [ -d "$VERIFY_ROOT/Payload/DualAI.app/Frameworks" ]; then
    verify_embedded_macho "$VERIFY_ROOT/Payload/DualAI.app/Frameworks"
fi
PACKAGED_ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$VERIFY_ROOT/Payload/DualAI.app" 2>/dev/null || true)"
echo "$PACKAGED_ENTITLEMENTS" | /usr/bin/grep -q '<key>get-task-allow</key>' \
    || fail "packaged app lost get-task-allow"

echo "Created: $IPA_PATH"
echo "Validated: Payload/DualAI.app, Info.plist, arm64 executable, stripped/signed Gecko Mach-O, get-task-allow"
