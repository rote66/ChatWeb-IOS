#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECT_PATH="$PROJECT_ROOT/DualAI.xcodeproj"
DERIVED_DATA="$PROJECT_ROOT/build/DerivedDataIPA"
PRODUCT_APP="$DERIVED_DATA/Build/Products/Release-iphoneos/DualAI.app"
DIST_DIR="$PROJECT_ROOT/dist"
IPA_PATH="$DIST_DIR/DualAI.ipa"
DEVELOPER_PATH="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
XCODEBUILD="$DEVELOPER_PATH/usr/bin/xcodebuild"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -d "$PROJECT_PATH" ] || fail "missing project: $PROJECT_PATH"
[ -x "$XCODEBUILD" ] || fail "missing xcodebuild: $XCODEBUILD"
mkdir -p "$DERIVED_DATA" "$DIST_DIR"

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
    clean build

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
/usr/bin/codesign --force --sign - --timestamp=none --generate-entitlement-der "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"

/bin/rm -f "$IPA_PATH"
(
    cd "$PACKAGE_ROOT"
    /usr/bin/zip -qry "$IPA_PATH" Payload
)

VERIFY_ROOT="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/chatweb-verify.XXXXXX")"
trap '/bin/rm -rf "$PACKAGE_ROOT" "$VERIFY_ROOT"' EXIT
/usr/bin/unzip -q "$IPA_PATH" -d "$VERIFY_ROOT"
[ -d "$VERIFY_ROOT/Payload/DualAI.app" ] || fail "IPA does not contain Payload/DualAI.app"
[ -f "$VERIFY_ROOT/Payload/DualAI.app/Info.plist" ] || fail "IPA app has no Info.plist"
[ -x "$VERIFY_ROOT/Payload/DualAI.app/DualAI" ] || fail "IPA app has no executable"
/usr/bin/plutil -lint "$VERIFY_ROOT/Payload/DualAI.app/Info.plist" >/dev/null
/usr/bin/lipo "$VERIFY_ROOT/Payload/DualAI.app/DualAI" -verify_arch arm64 || fail "packaged executable is not arm64"

echo "Created: $IPA_PATH"
echo "Validated: Payload/DualAI.app, Info.plist, arm64 executable, ad-hoc signature"
