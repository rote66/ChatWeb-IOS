#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${GECKO_SOURCE_DIR:-$PROJECT_ROOT/build/firefox-src}"
OBJ_DIR="${GECKO_OBJ_DIR:-$SOURCE_DIR/obj-gemini-gecko-ios-arm64}"
DIST_BIN="$OBJ_DIR/dist/bin"
INSTALL_MANIFEST="$OBJ_DIR/_build_manifests/install/dist_bin"
STAGE_DIR="${1:-$PROJECT_ROOT/build/GeckoRuntimeClean}"

case "$STAGE_DIR" in
    /*) ;;
    *) STAGE_DIR="$PROJECT_ROOT/$STAGE_DIR" ;;
esac
FINAL_STAGE_DIR="$STAGE_DIR"
WORK_STAGE_DIR="${FINAL_STAGE_DIR}.new.$$"
OLD_STAGE_DIR="${FINAL_STAGE_DIR}.old.$$"
STAGE_DIR="$WORK_STAGE_DIR"
TRACK_FILE="$STAGE_DIR/.install-manifest.track"

cleanup_stage() {
    /bin/rm -rf "$WORK_STAGE_DIR" "$OLD_STAGE_DIR"
}
trap cleanup_stage EXIT

fail() {
    echo "error: $*" >&2
    exit 1
}

[ -x "$SOURCE_DIR/mach" ] || fail "missing mach: $SOURCE_DIR/mach"
[ -d "$DIST_BIN" ] || fail "missing Gecko dist/bin: $DIST_BIN"
[ -f "$DIST_BIN/XUL" ] || fail "missing Gecko XUL: $DIST_BIN/XUL"
[ -f "$INSTALL_MANIFEST" ] || fail "missing Gecko dist_bin install manifest: $INSTALL_MANIFEST"
[ -f "$DIST_BIN/dependentlibs.list" ] || fail "missing dependentlibs.list"

# Always create a fresh tree off to the side. Gecko's dist/bin is incremental and can retain
# files removed by later moz.build trimming; install-manifest entries are the
# authoritative source-installed payload. Do not reuse a global --track file
# with a freshly deleted destination: process_install_manifest may otherwise
# consider generated entries unchanged while the destination is empty.
/bin/rm -rf "$WORK_STAGE_DIR" "$OLD_STAGE_DIR"
/bin/mkdir -p "$STAGE_DIR"

(
    cd "$SOURCE_DIR"
    # Prefer the already-created Mozilla build virtualenv.  `mach python` can
    # fail after an interrupted/recreated mach site even though the build venv
    # itself is healthy (for example when the mach site is temporarily missing
    # the `blessed` package).
    MOZBUILD_PYTHON=""
    MOZBUILD_STATE_ROOT="${MOZBUILD_STATE_PATH:-$HOME/.mozbuild}"
    if [ -d "$MOZBUILD_STATE_ROOT/srcdirs" ]; then
        while IFS= read -r candidate; do
            if "$candidate" -c 'import mozbuild' >/dev/null 2>&1; then
                MOZBUILD_PYTHON="$candidate"
                break
            fi
        done < <(/usr/bin/find "$MOZBUILD_STATE_ROOT/srcdirs" \
            -path '*/_virtualenvs/build/bin/python' -type f -print)
    fi

    if [ -n "$MOZBUILD_PYTHON" ]; then
        "$MOZBUILD_PYTHON" python/mozbuild/mozbuild/action/process_install_manifest.py \
            "$STAGE_DIR" \
            "$INSTALL_MANIFEST" \
            --track "$TRACK_FILE" \
            --no-symlinks
    else
        ./mach python python/mozbuild/mozbuild/action/process_install_manifest.py \
            "$STAGE_DIR" \
            "$INSTALL_MANIFEST" \
            --track "$TRACK_FILE" \
            --no-symlinks
    fi
)
/bin/rm -f "$TRACK_FILE"

# Several critical Gecko runtime files are generated during the build and are
# represented in the install manifest as generated/optional entries rather
# than ordinary source copies. process_install_manifest alone does not place
# them in a fresh standalone staging directory. The upstream Reynard iOS packer
# copies these from dist/bin, and XRE startup expects them under xreDirectory.
copy_generated_file() {
    local name="$1"
    [ -f "$DIST_BIN/$name" ] || fail "generated Gecko runtime file missing: $name"
    /bin/cp -f "$DIST_BIN/$name" "$STAGE_DIR/$name"
}

copy_generated_dir() {
    local name="$1"
    [ -d "$DIST_BIN/$name" ] || fail "generated Gecko runtime directory missing: $name"
    /bin/mkdir -p "$STAGE_DIR/$name"
    # dist/bin is a development tree and many of these entries are absolute
    # symlinks back into the Firefox source. iOS bundles may not contain those
    # links, so materialize their targets into the standalone runtime.
    /usr/bin/rsync -aL --delete "$DIST_BIN/$name/" "$STAGE_DIR/$name/"
}

for name in application.ini platform.ini greprefs.js default.locale chrome.manifest; do
    copy_generated_file "$name"
done

for name in chrome localization dictionaries modules; do
    copy_generated_dir "$name"
done

# The fresh standalone runtime also needs Firefox iOS' generated default
# preferences.  In the objdir this lives under defaults/pref/mobile.js, but it
# is not materialized by process_install_manifest into a fresh stage.  Omitting
# it leaves mobile-only prefs such as dom.meta-viewport.enabled at their static
# desktop defaults, so Gecko renders mobile pages using a desktop-width layout
# viewport.  Copy only mobile.js; PdfJsDefaultPrefs.js and backgroundtasks are
# intentionally excluded by this slim runtime.
/bin/mkdir -p "$STAGE_DIR/defaults/pref"
[ -f "$DIST_BIN/defaults/pref/mobile.js" ] || \
    fail "generated Firefox iOS mobile prefs missing: defaults/pref/mobile.js"
/bin/cp -f "$DIST_BIN/defaults/pref/mobile.js" \
    "$STAGE_DIR/defaults/pref/mobile.js"

# The UIKit build intentionally omits the WebExtensions product JS bundle, but
# ExtensionsParent is still linked because PExtensions/PDocumentChannel use the
# process-level extension actor.  Real document navigation calls
# ExtensionsParent::WebNavigation(), which imports WebNavigation.sys.mjs as an
# infallible XPCOM module.  Keep this one runtime service even though the rest
# of the WebExtensions product layer remains trimmed.
WEBNAV_SRC="$SOURCE_DIR/toolkit/components/extensions/WebNavigation.sys.mjs"
[ -f "$WEBNAV_SRC" ] || fail "missing WebNavigation runtime source: $WEBNAV_SRC"
/bin/cp -f "$WEBNAV_SRC" "$STAGE_DIR/modules/WebNavigation.sys.mjs"

# Gemini Phase 1 does not use Firefox's built-in PDF viewer, remote automation
# (Marionette/WebDriver BiDi), or DevTools chrome packages. They are large
# generated chrome trees and are not needed for ordinary web content, file
# upload, networking, storage, or GeckoView embedding. Remove both payloads
# and their root chrome.manifest registrations so startup never resolves a
# package that is intentionally absent.
/bin/rm -rf \
    "$STAGE_DIR/chrome/pdfjs" \
    "$STAGE_DIR/chrome/remote" \
    "$STAGE_DIR/chrome/devtools" \
    "$STAGE_DIR/chrome/devtools-startup"
/bin/rm -f \
    "$STAGE_DIR/chrome/pdfjs.manifest" \
    "$STAGE_DIR/chrome/remote.manifest" \
    "$STAGE_DIR/chrome/devtools.manifest" \
    "$STAGE_DIR/chrome/devtools-startup.manifest"

python3 - "$STAGE_DIR/chrome.manifest" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
drop = {
    "manifest chrome/pdfjs.manifest",
    "manifest chrome/remote.manifest",
    "manifest chrome/devtools.manifest",
    "manifest chrome/devtools-startup.manifest",
}
lines = [line for line in path.read_text().splitlines() if line not in drop]
path.write_text("\n".join(lines) + "\n")
PY

# Matching localization bundles are product UI only once the packages above
# are gone. Keep security/network/DOM/toolkit-global localization intact.
/bin/rm -rf \
    "$STAGE_DIR/localization/en-US/devtools" \
    "$STAGE_DIR/localization/en-US/toolkit/pdfviewer"

# The reference iOS embedding ships the default Firefox theme separately from
# dist/bin and registers it in chrome.manifest. Missing it can abort Gecko UI
# resource initialization before UIApplicationMain is reached.
DEFAULT_THEME_SRC="$SOURCE_DIR/toolkit/mozapps/extensions/default-theme"
[ -d "$DEFAULT_THEME_SRC" ] || fail "missing default theme source: $DEFAULT_THEME_SRC"
/bin/mkdir -p "$STAGE_DIR/default-theme"
/usr/bin/rsync -aL --delete "$DEFAULT_THEME_SRC/" "$STAGE_DIR/default-theme/"
if ! /usr/bin/grep -q '^resource default-theme file:default-theme/$' "$STAGE_DIR/chrome.manifest"; then
    echo 'resource default-theme file:default-theme/' >> "$STAGE_DIR/chrome.manifest"
fi

copy_native() {
    local name="$1"
    [ -f "$DIST_BIN/$name" ] || fail "dependent Gecko library missing: $name"
    /bin/cp -f "$DIST_BIN/$name" "$STAGE_DIR/$name"
}

while IFS= read -r name; do
    [ -n "$name" ] || continue
    copy_native "$name"
done < "$DIST_BIN/dependentlibs.list"

# NSS loads softokn dynamically, so it is not emitted by dependentlibs.list.
copy_native "libsoftokn3.dylib"

# Reduce the generated Firefox product chrome to the GeckoView/Phase-1 runtime
# closure.  This operates only on the disposable staging tree; the objdir and
# source checkout remain untouched.
python3 "$PROJECT_ROOT/scripts/trim_gecko_runtime.py" "$STAGE_DIR"

# Phase-1 Gemini does not need language hyphenation dictionaries. Keep Gecko's
# CSS hyphenation implementation, but omit the standalone en-US data file from
# the staged app. The Gecko objdir remains untouched.
/bin/rm -f "$STAGE_DIR/hyphenation/hyph_en_US.hyf"

# These Firefox-product resources should be absent because of the UIKit
# moz.build overlays. Assert that the fresh install manifest really reflects
# those trims, so stale incremental files can never leak back into the IPA.
if /usr/bin/find "$STAGE_DIR/modules" -maxdepth 1 -type f -name 'FxAccounts*.sys.mjs' -print -quit 2>/dev/null | /usr/bin/grep -q .; then
    fail "Firefox Accounts modules unexpectedly present in staged UIKit runtime"
fi
[ ! -f "$STAGE_DIR/modules/NewTabUtils.sys.mjs" ] || fail "NewTabUtils unexpectedly present in staged UIKit runtime"
[ ! -f "$STAGE_DIR/modules/Troubleshoot.sys.mjs" ] || fail "Troubleshoot unexpectedly present in staged UIKit runtime"
[ ! -f "$STAGE_DIR/modules/LightweightThemeConsumer.sys.mjs" ] || fail "LightweightThemeConsumer unexpectedly present in staged UIKit runtime"
[ ! -f "$STAGE_DIR/modules/third_party/fathom/fathom.mjs" ] || fail "Fathom unexpectedly present in staged UIKit runtime"
[ ! -f "$STAGE_DIR/chrome/devtools/modules/devtools/shared/DevToolsUtils.js" ] || fail "DevTools JS unexpectedly present in staged UIKit runtime"

[ -f "$STAGE_DIR/XUL" ] || fail "staged runtime has no XUL"

# Gecko natively prefers greDir/omni.ja over a flat chrome.manifest/resource
# tree. Pack the already-trimmed UIKit resources with Mozilla's own Jarrer so
# the iOS app stores JS/chrome/defaults/localization compressed on disk while
# keeping XUL and dependent Mach-O libraries as ordinary files. The packer
# validates the manifest/startup closure before deleting any flat resources.
(
    cd "$SOURCE_DIR"
    ./mach python "$PROJECT_ROOT/scripts/pack_gecko_omnijar.py" "$STAGE_DIR"
)
[ -f "$STAGE_DIR/omni.ja" ] || fail "staged runtime has no omni.ja"

FILE_COUNT="$(/usr/bin/find "$STAGE_DIR" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ')"

# Publish the complete tree only after every copy/assertion succeeds. Renaming
# within build/ is atomic, so Xcode can never observe a half-deleted/half-built
# Gecko runtime while a new staging pass is running.
if [ -e "$FINAL_STAGE_DIR" ]; then
    /bin/mv "$FINAL_STAGE_DIR" "$OLD_STAGE_DIR"
fi
/bin/mv "$WORK_STAGE_DIR" "$FINAL_STAGE_DIR"
/bin/rm -rf "$OLD_STAGE_DIR"
trap - EXIT

echo "Gecko runtime staged: $FINAL_STAGE_DIR"
echo "Files: $FILE_COUNT"
