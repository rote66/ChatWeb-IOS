#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INFO_PLIST="$PROJECT_ROOT/DualAI/Info.plist"
PROJECT_FILE="$PROJECT_ROOT/DualAI.xcodeproj/project.pbxproj"

fail() {
    echo "error: $*" >&2
    exit 1
}

/usr/bin/plutil -lint "$INFO_PLIST" "$PROJECT_FILE"

for key in NSCameraUsageDescription NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription NSPhotoLibraryUsageDescription NSPhotoLibraryAddUsageDescription; do
    /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" >/dev/null 2>&1 || fail "Info.plist missing $key"
done

/usr/bin/grep -q 'IPHONEOS_DEPLOYMENT_TARGET = 13.0;' "$PROJECT_FILE" || fail "deployment target is not 13.0"

SOURCE_MATCHES="$(/usr/bin/grep -R -n -E 'WKHTTPCookieStore|HTTPCookieStorage|customUserAgent|User-Agent|allowsAnyHTTPSCertificate|SecTrustEvaluate|setAllowsAnyHTTPSCertificate|dlopen\(|dlsym\(|ptrace\(|task_for_pid\(|platform-application|com\.apple\.private' "$PROJECT_ROOT/DualAI" "$PROJECT_ROOT/GeckoPrototype" --include='*.swift' --include='*.m' --include='*.mm' --include='*.h' --include='*.plist' || true)"
[ -z "$SOURCE_MATCHES" ] || fail "forbidden API or entitlement marker found:\n$SOURCE_MATCHES"

if /usr/bin/find "$PROJECT_ROOT" -path "$PROJECT_ROOT/build" -prune -o -name '*.entitlements' -print | /usr/bin/grep -q .; then
    fail "unexpected entitlement file found"
fi

if [ "${1:-}" != "" ]; then
    APP_PATH="$1"
    [ -d "$APP_PATH" ] || fail "app path not found: $APP_PATH"
    ENTITLEMENTS="$(/usr/bin/codesign -d --entitlements :- "$APP_PATH" 2>/dev/null || true)"
    if echo "$ENTITLEMENTS" | /usr/bin/grep -E -q 'platform-application|com\.apple\.private|task_for_pid-allow|com\.apple\.system-task-ports'; then
        fail "dangerous entitlement found in app"
    fi
fi

echo "Static checks passed: permissions, iOS 13 target, cookie/security/private API markers, entitlements"
