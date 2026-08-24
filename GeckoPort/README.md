# DualAI Gecko port

This directory owns the reproducible Firefox-source inputs for the embedded
Gecko engine. The browser shell is not vendored. The port is represented by one
canonical source patch, similar to the workflow used by Reynard:

- `PATCHSET.lock` pins the exact Firefox tag/commit and the canonical patch hash.
- `DualAI-Gecko.patch` is the complete source delta from the locked Firefox
  commit to the DualAI iOS/Gecko source currently used to build XUL.
- `mozconfig.ios13-arm64` defines the Release arm64 iOS 13+ build configuration.
- `apply_patches.sh` verifies commit + SHA-256 and applies the single patch.
- `build_gecko.sh` builds the patched source into
  `obj-gemini-gecko-ios-arm64`.
- `regenerate_patch.sh` rebuilds the canonical patch from a deliberately edited
  Firefox checkout. Generated `build/` and `obj-*` content is excluded.

The historical split Reference/Project patch queue has been retired as a build
input. Its useful source delta is fully represented in `DualAI-Gecko.patch`, so
future changes have one source of truth rather than an ordered collection of
overlays.

## Source lifecycle

Starting from a clean checkout at the locked commit:

```bash
git clone --depth 1 --single-branch \
  --branch FIREFOX_153_0_4_RELEASE --filter=blob:none \
  https://github.com/mozilla-firefox/firefox.git build/firefox-src
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  build/firefox-src/mach bootstrap \
    --application-choice browser --no-system-changes
bash GeckoPort/apply_patches.sh build/firefox-src
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash GeckoPort/build_gecko.sh build/firefox-src
bash scripts/export_gecko_prebuilt.sh
```

`export_gecko_prebuilt.sh` does not delete the Firefox objdir. It stages the
runtime, exports the three consumer headers needed by the app, and refreshes
the compressed `GeckoPrebuilt/GeckoCore-ios-arm64.zip` artifact.

After the export, the normal app/IPA build must consume that prebuilt artifact:

```bash
bash scripts/prepare_gecko_prebuilt.sh
bash scripts/static_check.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/build_ipa.sh
```

The source diff, canonical patch, patch lock, objdir XUL, prebuilt manifest and
archive are one release unit. Do not commit a Gecko source change without
refreshing and verifying all of them.

To intentionally reset only Firefox source back to the lock before reapplying
the patch, use `reset_source.sh`. This does not remove ignored Gecko objdirs or
the exported prebuilt kernel.

## Updating the canonical patch

After editing the patched Firefox checkout:

```bash
bash GeckoPort/regenerate_patch.sh build/firefox-src
```

Copy the printed SHA-256 to `CANONICAL_PATCH_SHA256` in `PATCHSET.lock`, then
verify the patch against a fresh locked checkout before committing it.

The reference patchset commit remains recorded in `PATCHSET.lock` for audit and
attribution. DualAI does not embed the reference browser application or its UI.
