#!/usr/bin/env python3
"""Pack the staged UIKit Gecko resource tree into Gecko's native omni.ja.

Run this with Firefox's `mach python` so the in-tree mozpack modules are
available. Native Mach-O files and app metadata stay outside the archive;
Gecko JS/chrome/defaults/localization resources are compressed into omni.ja
using the same Jarrer implementation as Mozilla's installer packager.
"""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

from mozpack.copier import Jarrer
from mozpack.files import File


def fail(message: str) -> None:
    raise SystemExit(f"pack_gecko_omnijar: {message}")


def is_mozilla_resource(rel: str) -> bool:
    """Mirror OmniJarSubFormatter.is_resource() for this runtime."""
    path = rel.split("/")
    if path[0] == "chrome":
        return len(path) == 1 or path[1] != "icons"
    if path[0] == "components":
        return path[-1].endswith((".js", ".xpt"))
    if path[0] == "res":
        return len(path) == 1 or path[1] not in (
            "cursors",
            "touchbar",
            "MainMenu.nib",
        )
    if path[0] == "defaults":
        return len(path) != 3 or not (
            path[2] == "channel-prefs.js"
            and path[1] in ("pref", "preferences")
        )
    if len(path) <= 2 and path[-1] == "greprefs.js":
        return True
    return path[0] in (
        "modules",
        "moz-src",
        "actors",
        "dictionaries",
        "hyphenation",
        "localization",
        "default.locale",
        "contentaccessible",
    )


def is_omni_entry(rel: str) -> bool:
    # OmniJarFormatter.add_manifest() puts all non-binary manifests into the
    # omnijar even when the manifest path isn't classified as a normal
    # resource. The UIKit runtime has no binary-component manifests.
    if rel == "chrome.manifest":
        return True
    if rel.startswith("components/") and rel.endswith(".manifest"):
        return True

    # DualAI adds this resource alias itself. Because the root manifest moves
    # into omni.ja, keep the tiny theme tree beside it so its relative file:
    # target continues to resolve within the same FileLocation.
    if rel.startswith("default-theme/"):
        return True
    return is_mozilla_resource(rel)


def all_files(root: Path) -> list[tuple[Path, str]]:
    files: list[tuple[Path, str]] = []
    for path in root.rglob("*"):
        if path.is_file():
            files.append((path, path.relative_to(root).as_posix()))
    return files


def remove_empty_dirs(root: Path) -> None:
    for path in sorted((p for p in root.rglob("*") if p.is_dir()), reverse=True):
        try:
            path.rmdir()
        except OSError:
            pass


def validate_archive(stage: Path, omni_path: Path) -> int:
    try:
        with zipfile.ZipFile(omni_path) as archive:
            bad = archive.testzip()
            if bad:
                fail(f"corrupt omnijar entry: {bad}")
            names = set(archive.namelist())
            try:
                root_manifest = archive.read("chrome.manifest").decode("utf-8")
            except KeyError:
                fail("chrome.manifest missing from omnijar")
    except zipfile.BadZipFile as exc:
        fail(f"invalid omnijar: {exc}")

    missing_manifests: list[str] = []
    for line in root_manifest.splitlines():
        if line.startswith("manifest "):
            target = line.split(None, 1)[1]
            if target not in names:
                missing_manifests.append(target)
    if missing_manifests:
        fail(
            "root manifest has missing omnijar targets: "
            + ", ".join(missing_manifests)
        )

    required_entries = (
        "chrome.manifest",
        "chrome/toolkit.manifest",
        "chrome/geckoview/content/geckoview.xhtml",
        "chrome/geckoview/content/geckoview.js",
        "modules/GeckoViewStartup.sys.mjs",
        "modules/GeckoViewNavigation.sys.mjs",
        "modules/GeckoViewProgress.sys.mjs",
        "modules/GeckoViewPrompt.sys.mjs",
        "modules/GeckoViewPermission.sys.mjs",
        "modules/psm/RemoteSecuritySettings.sys.mjs",
        "modules/SafeBrowsing.sys.mjs",
        "defaults/pref/mobile.js",
        "greprefs.js",
    )
    missing_required = [name for name in required_entries if name not in names]
    if missing_required:
        fail("required entries missing: " + ", ".join(missing_required))

    if not any(name.startswith("default-theme/") for name in names):
        fail("default-theme tree missing from omnijar")

    outer_required = (
        "XUL",
        "application.ini",
        "platform.ini",
        "libnss3.dylib",
        "libgkcodecs.dylib",
        "libmozglue.dylib",
        "libfreebl3.dylib",
        "libsoftokn3.dylib",
    )
    missing_outer = [name for name in outer_required if not (stage / name).is_file()]
    if missing_outer:
        fail("required outer files missing: " + ", ".join(missing_outer))

    return len(names)


def main() -> None:
    if len(sys.argv) != 2:
        fail("usage: pack_gecko_omnijar.py STAGE_DIR")

    stage = Path(sys.argv[1]).resolve()
    if not (stage / "XUL").is_file():
        fail(f"staged runtime has no XUL: {stage}")
    if not (stage / "chrome.manifest").is_file():
        fail(f"flat staged runtime has no chrome.manifest: {stage}")

    omni_path = stage / "omni.ja"
    if omni_path.exists():
        fail(f"refusing to overwrite existing omnijar: {omni_path}")

    files = all_files(stage)
    omni_files = [(path, rel) for path, rel in files if is_omni_entry(rel)]
    if not omni_files:
        fail("no files selected for omnijar")

    raw_bytes = sum(path.stat().st_size for path, _ in omni_files)
    jarrer = Jarrer(compress=True)
    for path, rel in omni_files:
        jarrer.add(rel, File(str(path)))
    jarrer.copy(str(omni_path), skip_if_older=False)

    # Validate the complete archive before deleting a single flat resource.
    entry_count = validate_archive(stage, omni_path)

    for _, rel in omni_files:
        (stage / rel).unlink()
    remove_empty_dirs(stage)

    leaked = [
        rel
        for _, rel in all_files(stage)
        if rel != "omni.ja" and is_omni_entry(rel)
    ]
    if leaked:
        fail("packed resources still present outside omni.ja: " + ", ".join(leaked[:20]))

    packed_bytes = omni_path.stat().st_size
    print(f"Gecko omnijar packed: {omni_path}")
    print(f"Entries: {entry_count}")
    print(f"Resources: {raw_bytes} -> {packed_bytes} bytes")
    print(f"Saved installed bytes: {raw_bytes - packed_bytes}")


if __name__ == "__main__":
    main()
