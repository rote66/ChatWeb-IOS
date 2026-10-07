#!/usr/bin/env python3
"""Remove personal build-home prefixes from packaged Gecko runtime files."""

import argparse
import copy
import io
import re
import struct
import subprocess
import zipfile
from pathlib import Path


HOME_PREFIX = re.compile(rb"(?:/Users/|/home/)[A-Za-z0-9_.-]+")
MACHO_MAGIC = {b"\xcf\xfa\xed\xfe": "<", b"\xfe\xed\xfa\xcf": ">"}
TEXT_SUFFIXES = {".mjs", ".js", ".ini", ".json", ".h", ".manifest", ".properties", ".txt"}


def scrub_prefix(match):
    return b"/build/" + b"_" * (len(match.group()) - 7)


def sanitize_binary(path):
    data = path.read_bytes()
    endian = MACHO_MAGIC.get(data[:4])
    if endian is None:
        return 0
    matches = list(HOME_PREFIX.finditer(data))
    if not matches:
        return 0

    command_count, command_bytes = struct.unpack_from(endian + "II", data, 16)
    command_end = 32 + command_bytes
    instruction_ranges = []
    signed = False
    offset = 32
    for _ in range(command_count):
        command, size = struct.unpack_from(endian + "II", data, offset)
        if size < 8 or offset + size > command_end:
            raise ValueError(f"Invalid Mach-O load commands: {path.name}")
        signed |= command == 0x1D  # LC_CODE_SIGNATURE
        if command == 0x19:  # LC_SEGMENT_64
            section_count = struct.unpack_from(endian + "I", data, offset + 64)[0]
            for index in range(section_count):
                section = offset + 72 + index * 80
                length, start = struct.unpack_from(endian + "QI", data, section + 40)
                flags = struct.unpack_from(endian + "I", data, section + 64)[0]
                if flags & (0x80000000 | 0x400):
                    instruction_ranges.append((start, start + length))
        offset += size
    if offset != command_end:
        raise ValueError(f"Invalid Mach-O load-command size: {path.name}")

    cleaned = bytearray(data)
    for match in matches:
        if match.start() < command_end or any(
            match.start() < end and match.end() > start
            for start, end in instruction_ranges
        ):
            raise ValueError(f"Home path overlaps executable code or loader metadata: {path.name}")
        # Keep every string and file offset stable. Only diagnostic/source paths
        # and linker string-table entries may contain these build-home prefixes.
        cleaned[match.start():match.end()] = scrub_prefix(match)
    assert len(cleaned) == len(data)
    path.write_bytes(cleaned)
    if signed:
        subprocess.run(
            ["/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", path.name, str(path)],
            check=True,
        )
        subprocess.run(["/usr/bin/codesign", "--verify", "--strict", str(path)], check=True)
    if HOME_PREFIX.search(path.read_bytes()):
        raise ValueError(f"Personal build-home prefix remains: {path.name}")
    return len(matches)


def sanitize_omnijar(path):
    with zipfile.ZipFile(path) as original:
        members = [(copy.copy(item), original.read(item.filename)) for item in original.infolist()]
        comment = original.comment
    cleaned_members = []
    total = 0
    for item, data in members:
        if Path(item.filename).suffix in TEXT_SUFFIXES:
            data, count = HOME_PREFIX.subn(scrub_prefix, data)
            total += count
        cleaned_members.append((item, data))
    if not total:
        return 0
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as cleaned:
        cleaned.comment = comment
        for item, data in cleaned_members:
            cleaned.writestr(item, data, compress_type=item.compress_type, compresslevel=9)
    with zipfile.ZipFile(io.BytesIO(buffer.getvalue())) as checked:
        if checked.testzip() is not None:
            raise ValueError(f"Corrupt sanitized omnijar: {path.name}")
    path.write_bytes(buffer.getvalue())
    return total


def sanitize_runtime(runtime):
    total = 0
    for path in sorted(runtime.rglob("*")):
        if path.is_file() and not path.is_symlink():
            if path.suffix == ".ja":
                total += sanitize_omnijar(path)
            elif path.suffix in TEXT_SUFFIXES:
                cleaned, count = HOME_PREFIX.subn(scrub_prefix, path.read_bytes())
                if count:
                    path.write_bytes(cleaned)
                total += count
            else:
                total += sanitize_binary(path)
    return total


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("runtime", type=Path)
    args = parser.parse_args()
    if not args.runtime.is_dir():
        parser.error("runtime directory does not exist")
    print(f"Sanitized {sanitize_runtime(args.runtime)} embedded build-home prefixes")
