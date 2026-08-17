#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${1:-$PROJECT_ROOT/build/firefox-src}"

fail() {
    echo "error: $*" >&2
    exit 1
}

require_text() {
    local file="$1"
    local pattern="$2"
    [ -f "$SOURCE_DIR/$file" ] || fail "missing JIT source: $file"
    grep -F -q "$pattern" "$SOURCE_DIR/$file" || fail "missing JIT marker '$pattern' in $file"
}

require_text "toolkit/xre/IOSBootstrap.mm" "ReportJITStatusForChild"
require_text "toolkit/xre/IOSBootstrap.mm" "WaitForJITReadySignal"
require_text "toolkit/xre/IOSBootstrap.mm" "JS::DisableJitBackend"
require_text "ipc/glue/GeckoChildProcessHost.cpp" "NotifyChildProcessStarted"
require_text "js/src/jit/ProcessExecutableMemory.cpp" "SetJITRuntimeInfo"
require_text "js/src/jit/ProcessExecutableMemory.cpp" "RequestDebuggerToPrepareRegion"
require_text "js/src/jit/arm64/Assembler-arm64.cpp" "XP_IOS"
require_text "js/src/wasm/WasmCode.cpp" "WritableJitAllocationFromExecutable"

if grep -E -q '(^|[[:space:]])ac_add_options[[:space:]]+--disable-(ion|jit|baselinejit)' "$SCRIPT_DIR/mozconfig.ios13-arm64"; then
    fail "mozconfig disables a SpiderMonkey JIT tier"
fi

echo "JIT patchset verification passed"
