#!/usr/bin/env python3
"""Inspect a Hex docs archive against every regular file in its source tree."""

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import re
import sys
import tarfile


SEMVER = re.compile(
    r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def check(archive, directory):
    if not directory.is_dir():
        raise ValueError("Documentation source directory is missing.")
    source = {
        path.relative_to(directory).as_posix(): path
        for path in directory.rglob("*")
        if path.is_file()
    }
    names = set()
    with tarfile.open(archive, "r:gz") as packed:
        for member in packed:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or "\\" in member.name
                    or any(part in ("", ".", "..") for part in member.name.split("/"))):
                raise ValueError(f"Unsafe docs archive member: {member.name!r}")
            if SEMVER.fullmatch(path.parts[0]):
                raise ValueError("Top-level documentation filenames cannot be semantic versions.")
            if member.name in names:
                raise ValueError(f"Duplicate docs archive member: {member.name!r}")
            names.add(member.name)
            if member.name not in source:
                raise ValueError(f"Docs archive member has no source: {member.name!r}")
            if packed.extractfile(member).read() != source[member.name].read_bytes():
                raise ValueError(f"Docs archive bytes differ from source: {member.name!r}")
    if not {"index.html", "readme.html"} <= names:
        raise ValueError("Docs archive requires top-level index.html and readme.html.")
    if names != source.keys():
        raise ValueError(f"Docs archive omits source files: {sorted(source.keys() - names)!r}")
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    print(f"DOCS OK: {len(names)} regular files; all bytes match the source tree")
    print(f"SHA256: {digest}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path)
    parser.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        check(args.archive, args.directory)
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"Docs archive refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
