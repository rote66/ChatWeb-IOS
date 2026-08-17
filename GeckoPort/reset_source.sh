#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOCK_FILE="$SCRIPT_DIR/PATCHSET.lock"
SOURCE_DIR="${1:-$PROJECT_ROOT/build/firefox-src}"

FIREFOX_COMMIT="$(sed -n 's/^FIREFOX_COMMIT=//p' "$LOCK_FILE" | head -n 1)"
[ -n "$FIREFOX_COMMIT" ] || { echo "error: missing FIREFOX_COMMIT" >&2; exit 1; }
[ -d "$SOURCE_DIR/.git" ] || { echo "error: not a Git checkout: $SOURCE_DIR" >&2; exit 1; }

git -C "$SOURCE_DIR" reset --hard "$FIREFOX_COMMIT"
git -C "$SOURCE_DIR" clean -fd
echo "Reset Firefox source to $FIREFOX_COMMIT"
