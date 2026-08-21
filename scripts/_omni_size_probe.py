#!/usr/bin/env python3
import os
import zipfile

root = "build/GeckoRuntimeClean"
out = "build/omni-size-test.ja"


def is_resource(rel: str) -> bool:
    path = rel.split("/")
    if path[0] == "chrome":
        return len(path) == 1 or path[1] != "icons"
    if path[0] == "components":
        return path[-1].endswith((".js", ".xpt"))
    if path[0] == "res":
        return len(path) == 1 or path[1] not in ("cursors", "touchbar", "MainMenu.nib")
    if path[0] == "defaults":
        return len(path) != 3 or not (
            path[2] == "channel-prefs.js" and path[1] in ("pref", "preferences")
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


files = []
for dirpath, _, names in os.walk(root):
    for name in names:
        path = os.path.join(dirpath, name)
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        files.append((path, rel))

resources = [(path, rel) for path, rel in files if is_resource(rel)]
raw = sum(os.path.getsize(path) for path, _ in resources)

with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
    for path, rel in resources:
        archive.write(path, rel)

packed = os.path.getsize(out)
print(f"resource_files={len(resources)}")
print(f"resource_raw={raw} ({raw / 1048576:.3f} MiB)")
print(f"omni_zip={packed} ({packed / 1048576:.3f} MiB)")
print(f"saved={raw - packed} ({(raw - packed) / 1048576:.3f} MiB)")
print(
    f"nonresource_raw={sum(os.path.getsize(path) for path, rel in files if not is_resource(rel))}"
)
