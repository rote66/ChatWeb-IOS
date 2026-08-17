# Prebuilt Gecko core

`GeckoCore-ios-arm64.zip` is the app-facing prebuilt Gecko artifact. It exists
so normal DualAI development does not need to relink Firefox/XUL.

Tracked files:

```text
GeckoCore-ios-arm64.zip
MANIFEST.lock
README.md
```

Expanded files are intentionally ignored by Git:

```text
Runtime/
include/
```

Prepare them with:

```bash
bash scripts/prepare_gecko_prebuilt.sh
```

The Xcode target links `Runtime/XUL`, copies the rest of `Runtime` into the app,
and compiles the bridge against the headers under `include/`.

To refresh the artifact after a successful Gecko source build:

```bash
bash scripts/export_gecko_prebuilt.sh
```

The exporter first rebuilds the disposable slim runtime staging tree from the
Gecko objdir, then copies it here and creates a new compressed archive. It does
not clean the Firefox checkout or objdir.

`MANIFEST.lock` is generated alongside the archive and records the Firefox
revision, target, XUL SHA-256/size and runtime file count. The same manifest is
also embedded in the zip so extraction can detect an archive/manifest mismatch.

The zip is used instead of committing raw `Runtime/XUL` because the uncompressed
XUL is larger than GitHub's 100 MB single-file limit.
