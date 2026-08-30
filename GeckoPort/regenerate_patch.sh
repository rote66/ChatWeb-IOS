#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${1:-$PROJECT_ROOT/build/firefox-src}"
PATCH_FILE="$SCRIPT_DIR/ChatWeb-Gecko.patch"

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -d "$SOURCE_DIR/.git" ] || fail "Firefox source is not a Git checkout: $SOURCE_DIR"

# New source files must be represented in git diff. Mark non-build untracked
# files intent-to-add without staging their contents. Generated runtime/objdir
# directories are deliberately excluded from the source patch.
while IFS= read -r path; do
    case "$path" in
        build/*|obj-*/*) continue ;;
    esac
    git -C "$SOURCE_DIR" add -N -- "$path"
done < <(git -C "$SOURCE_DIR" ls-files --others --exclude-standard)

git -C "$SOURCE_DIR" diff HEAD --binary --full-index --output="$PATCH_FILE"

SHA256="$(/usr/bin/shasum -a 256 "$PATCH_FILE" | /usr/bin/awk '{print $1}')"
echo "Regenerated: $PATCH_FILE"
echo "SHA256: $SHA256"
echo "Update CANONICAL_PATCH_SHA256 in PATCHSET.lock to this value before committing."
