#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$SCRIPT_DIR/PATCHSET.lock"
SOURCE_DIR="${1:-$PROJECT_ROOT/build/firefox-src}"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -f "$LOCK_FILE" ] || fail "missing lock file: $LOCK_FILE"
[ -d "$SOURCE_DIR/.git" ] || fail "Firefox source is not a Git checkout: $SOURCE_DIR"

FIREFOX_COMMIT="$(sed -n 's/^FIREFOX_COMMIT=//p' "$LOCK_FILE" | head -n 1)"
CANONICAL_PATCH="$(sed -n 's/^CANONICAL_PATCH=//p' "$LOCK_FILE" | head -n 1)"
EXPECTED_PATCH_SHA256="$(sed -n 's/^CANONICAL_PATCH_SHA256=//p' "$LOCK_FILE" | head -n 1)"
[ -n "$FIREFOX_COMMIT" ] || fail "FIREFOX_COMMIT is missing from PATCHSET.lock"
[ -n "$CANONICAL_PATCH" ] || fail "CANONICAL_PATCH is missing from PATCHSET.lock"
[ -n "$EXPECTED_PATCH_SHA256" ] || fail "CANONICAL_PATCH_SHA256 is missing from PATCHSET.lock"

PATCH_FILE="$SCRIPT_DIR/$CANONICAL_PATCH"
[ -f "$PATCH_FILE" ] || fail "missing canonical Gecko patch: $PATCH_FILE"
ACTUAL_PATCH_SHA256="$(/usr/bin/shasum -a 256 "$PATCH_FILE" | /usr/bin/awk '{print $1}')"
[ "$ACTUAL_PATCH_SHA256" = "$EXPECTED_PATCH_SHA256" ] || \
    fail "canonical patch checksum mismatch: expected $EXPECTED_PATCH_SHA256, got $ACTUAL_PATCH_SHA256"

HEAD_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
[ "$HEAD_COMMIT" = "$FIREFOX_COMMIT" ] || fail "Firefox HEAD mismatch: expected $FIREFOX_COMMIT, got $HEAD_COMMIT"

[ -z "$(git -C "$SOURCE_DIR" status --porcelain)" ] || fail "Firefox source has local changes; reset it before applying the port queue"

echo "[canonical] $CANONICAL_PATCH"
git -C "$SOURCE_DIR" apply --check --binary "$PATCH_FILE"
git -C "$SOURCE_DIR" apply --index --binary --whitespace=nowarn "$PATCH_FILE"

echo "Applied canonical Gecko iOS patch to: $SOURCE_DIR"
