#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="${1:-$PROJECT_ROOT/build/firefox-src}"
BUILD_JOBS="${GECKO_BUILD_JOBS:-4}"
RUST_TOOLCHAIN="${GECKO_RUST_TOOLCHAIN:-1.94.1}"
OBJDIR="$SOURCE_DIR/obj-gemini-gecko-ios-arm64"

[ -x "$SOURCE_DIR/mach" ] || { echo "error: missing mach in $SOURCE_DIR" >&2; exit 1; }
case "$BUILD_JOBS" in
  ""|*[!0-9]*|0) echo "error: GECKO_BUILD_JOBS must be a positive integer" >&2; exit 1 ;;
esac

# Firefox 156 CI uses Rust 1.94.1 (LLVM 21.1.8), matching the Mozilla clang/lld
# downloaded by bootstrap. An unpinned stable toolchain may produce newer LLVM
# bitcode that the ThinLTO linker cannot read.
command -v rustup >/dev/null 2>&1 || {
  echo "error: rustup is required for the pinned Rust $RUST_TOOLCHAIN toolchain" >&2
  exit 1
}
if ! RUSTC_PATH="$(rustup which --toolchain "$RUST_TOOLCHAIN" rustc 2>/dev/null)" || \
   ! CARGO_PATH="$(rustup which --toolchain "$RUST_TOOLCHAIN" cargo 2>/dev/null)"; then
  echo "error: missing Rust $RUST_TOOLCHAIN; install it with:" >&2
  echo "       rustup toolchain install $RUST_TOOLCHAIN --profile minimal --target aarch64-apple-darwin,aarch64-apple-ios" >&2
  exit 1
fi
if ! rustup target list --toolchain "$RUST_TOOLCHAIN" --installed | \
     grep -qx 'aarch64-apple-ios'; then
  echo "error: Rust $RUST_TOOLCHAIN is missing the aarch64-apple-ios target; install it with:" >&2
  echo "       rustup target add --toolchain $RUST_TOOLCHAIN aarch64-apple-ios" >&2
  exit 1
fi
export RUSTC="$RUSTC_PATH"
export CARGO="$CARGO_PATH"

# Make does not treat RUSTC as a dependency of an existing libgkrust.a. Purge
# only Cargo outputs when the selected compiler changes, otherwise an old LLVM
# bitcode archive can survive configure and fail at the final XUL link.
RUST_LLVM_VERSION="$($RUSTC --version --verbose | sed -n 's/^LLVM version: //p')"
RUST_TOOLCHAIN_ID="$($RUSTC --version) | LLVM $RUST_LLVM_VERSION"
RUST_TOOLCHAIN_STAMP="$OBJDIR/.dualiai-rust-toolchain"
INSTALLED_RUST_TOOLCHAIN="$(sed -n '1p' "$RUST_TOOLCHAIN_STAMP" 2>/dev/null || true)"
if [ "$INSTALLED_RUST_TOOLCHAIN" != "$RUST_TOOLCHAIN_ID" ]; then
  if [ -d "$OBJDIR/aarch64-apple-ios/release" ] || [ -d "$OBJDIR/release" ]; then
    echo "Rust toolchain changed; removing stale Cargo outputs from $OBJDIR"
    rm -rf -- "$OBJDIR/aarch64-apple-ios/release" "$OBJDIR/release"
    rm -f -- "$OBJDIR/.rustc_info.json"
  fi
  mkdir -p "$OBJDIR"
  printf '%s\n' "$RUST_TOOLCHAIN_ID" > "$RUST_TOOLCHAIN_STAMP"
fi

# MCP command timeouts can leave mach/make/cargo/clang/linker descendants alive.
# Refuse to start another build while any Gecko build stage is still present;
# this prevents multiple stale builds from thrashing swap on the 16 GiB host.
if [ "${GECKO_ALLOW_CONCURRENT_BUILD:-0}" != "1" ]; then
  if pgrep -f "[m]ach build" >/dev/null 2>&1 || \
     pgrep -f "[m]ake -f client.mk" >/dev/null 2>&1 || \
     pgrep -f "[c]argo rustc.*toolkit/library/rust/Cargo.toml" >/dev/null 2>&1 || \
     pgrep -f "[c]lang.*obj-gemini-gecko-ios-arm64" >/dev/null 2>&1 || \
     pgrep -f "[l]d64.lld.*XUL" >/dev/null 2>&1; then
    echo "error: an existing Gecko build process is still running; do not start a duplicate build" >&2
    echo "       set GECKO_ALLOW_CONCURRENT_BUILD=1 only for an intentional concurrent build" >&2
    exit 2
  fi
fi

IOS_SDK_PATH="${IOS_SDK_PATH:-$(xcrun --sdk iphoneos --show-sdk-path)}"
[ -d "$IOS_SDK_PATH" ] || { echo "error: invalid iOS SDK path: $IOS_SDK_PATH" >&2; exit 1; }

"$SCRIPT_DIR/verify_jit_patchset.sh" "$SOURCE_DIR"
rsync -a "$SCRIPT_DIR/mozconfig.ios13-arm64" "$SOURCE_DIR/.mozconfig"
echo "ac_add_options --with-ios-sdk=$IOS_SDK_PATH" >> "$SOURCE_DIR/.mozconfig"

cd "$SOURCE_DIR"
echo "Using $($RUSTC --version) for Gecko"
# Re-evaluate compiler paths even for an existing objdir.
./mach configure
./mach build -j"$BUILD_JOBS"
