#!/usr/bin/env python3
"""Build a disposable Gecko runtime using Mozilla's Jarrer omnijar format."""

from __future__ import annotations

import os
import shutil
import zipfile
from pathlib import Path

from mozpack.copier import Jarrer
from mozpack.files import File


PROJECT_ROOT = Path(__file__).resolve().parents[1]
SOURCE = PROJECT_ROOT / "build/GeckoRuntimeClean"
DEST = PROJECT_ROOT / "build/GeckoRuntimeOmniProbe"


def is_mozilla_resource(rel: str) -> bool:
    """Mirror OmniJarSubFormatter.is_resource() for this staged runtime."""
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
    # OmniJarFormatter.add_manifest() puts all non-binary manifests in the
    # omnijar even when their path isn't classified as a normal resource.
    if rel == "chrome.manifest":
        return True
    if rel.startswith("components/") and rel.endswith(".manifest"):
        return True

    # ChatWeb registers this tree from the root chrome.manifest using a relative
    # file: URI. Keep the tiny tree beside that manifest inside the archive so
    # the relative target remains valid after switching from flat to omnijar.
    if rel.startswith("default-theme/"):
        return True
    return is_mozilla_resource(rel)


def all_files(root: Path) -> list[tuple[Path, str]]:
    result: list[tuple[Path, str]] = []
    for path in root.rglob("*"):
        if path.is_file():
            result.append((path, path.relative_to(root).as_posix()))
    return result


def remove_empty_dirs(root: Path) -> None:
    for path in sorted((p for p in root.rglob("*") if p.is_dir()), reverse=True):
        try:
            path.rmdir()
        except OSError:
            pass


def main() -> None:
    if not (SOURCE / "XUL").is_file():
        raise SystemExit(f"missing staged runtime: {SOURCE}")

    shutil.rmtree(DEST, ignore_errors=True)
    shutil.copytree(SOURCE, DEST, symlinks=False)

    source_files = all_files(SOURCE)
    omni_files = [(path, rel) for path, rel in source_files if is_omni_entry(rel)]
    raw_omni_bytes = sum(path.stat().st_size for path, _ in omni_files)
    raw_total_bytes = sum(path.stat().st_size for path, _ in source_files)

    jarrer = Jarrer(compress=True)
    for path, rel in omni_files:
        jarrer.add(rel, File(str(path)))
    omni_path = DEST / "omni.ja"
    jarrer.copy(str(omni_path), skip_if_older=False)

    for _, rel in omni_files:
        (DEST / rel).unlink()
    remove_empty_dirs(DEST)

    with zipfile.ZipFile(omni_path) as archive:
        bad = archive.testzip()
        if bad:
            raise SystemExit(f"corrupt omnijar entry: {bad}")
        names = set(archive.namelist())
        root_manifest = archive.read("chrome.manifest").decode("utf-8")

    missing_manifests: list[str] = []
    for line in root_manifest.splitlines():
        if line.startswith("manifest "):
            target = line.split(None, 1)[1]
            if target not in names:
                missing_manifests.append(target)
    if missing_manifests:
        raise SystemExit(
            "omnijar root manifest has missing targets: "
            + ", ".join(missing_manifests)
        )

    required_entries = (
        "chrome.manifest",
        "chrome/toolkit.manifest",
        "chrome/geckoview/content/geckoview.xhtml",
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
        raise SystemExit(
            "required omnijar entries missing: " + ", ".join(missing_required)
        )
    if not any(name.startswith("default-theme/") for name in names):
        raise SystemExit("default-theme tree missing from omnijar")

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
    missing_outer = [name for name in outer_required if not (DEST / name).is_file()]
    if missing_outer:
        raise SystemExit("required outer files missing: " + ", ".join(missing_outer))

    leaked = [rel for _, rel in all_files(DEST) if rel != "omni.ja" and is_omni_entry(rel)]
    if leaked:
        raise SystemExit("packed resources still present outside omnijar: " + ", ".join(leaked[:20]))

    final_files = all_files(DEST)
    final_bytes = sum(path.stat().st_size for path, _ in final_files)
    omni_bytes = omni_path.stat().st_size
    print(f"source_files={len(source_files)}")
    print(f"omni_entries={len(omni_files)}")
    print(f"omni_raw={raw_omni_bytes} ({raw_omni_bytes / 1048576:.3f} MiB)")
    print(f"omni_packed={omni_bytes} ({omni_bytes / 1048576:.3f} MiB)")
    print(f"source_total={raw_total_bytes} ({raw_total_bytes / 1048576:.3f} MiB)")
    print(f"probe_total={final_bytes} ({final_bytes / 1048576:.3f} MiB)")
    print(f"saved={raw_total_bytes - final_bytes} ({(raw_total_bytes - final_bytes) / 1048576:.3f} MiB)")
    print(f"probe_files={len(final_files)}")


if __name__ == "__main__":
    main()
