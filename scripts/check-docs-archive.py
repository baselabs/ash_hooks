#!/usr/bin/env python3
"""Inspect a Hex docs archive and the release.json that names its commit.

With a source tree, the archive must hold exactly the tree's visible regular
files and bytes, and release.json must name this package, the version and the
building commit. With --served, an archive Hex already serves must be a safe
docs archive with its entry pages; its bytes are never compared with a build.
Its release.json must name this package and version, and a commit that is the
dispatched commit or an ancestor of it: that commit is the published commit.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tarfile

PACKAGE = "ash_hooks"
SEMVER = re.compile(
    r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)
COMMIT = re.compile(r"[0-9a-f]{40}")


def release(data, version):
    try:
        record = json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise ValueError("release.json is not a JSON object.") from None
    if (not isinstance(record, dict) or set(record) != {"package", "version", "commit"}
            or record["package"] != PACKAGE or record["version"] != version
            or not isinstance(record["commit"], str) or not COMMIT.fullmatch(record["commit"])):
        raise ValueError(f"release.json does not name {PACKAGE} {version} and a full commit SHA.")
    return record["commit"]


def published(commit, dispatched, repo):
    if commit == dispatched:
        return commit
    # The dispatched commit is the default branch's head, so its ancestors are
    # that branch's history.
    status = subprocess.run(
        ["git", "-C", str(repo), "merge-base", "--is-ancestor", commit, dispatched],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ).returncode
    if status == 0:
        return commit
    if status == 1:
        raise ValueError(f"release.json names {commit}, off the default branch history.")
    raise ValueError(f"release.json names {commit}, which this repository does not have.")


def check(archive, directory, version, commit, repo):
    served = directory is None
    if not served and not directory.is_dir():
        raise ValueError("Documentation source directory is missing.")
    # mix hex.publish lists the tree with Path.wildcard/1, which matches no
    # file or directory whose name starts with a dot.
    source = {}
    for path in [] if served else directory.rglob("*"):
        relative = path.relative_to(directory)
        if path.is_file() and not any(part.startswith(".") for part in relative.parts):
            source[relative.as_posix()] = path
    names = set()
    named = None
    with tarfile.open(archive, "r:gz") as packed:
        for member in packed:
            path = PurePosixPath(member.name)
            if (not member.isfile() or path.is_absolute() or "\\" in member.name
                    or any(part in ("", ".", "..") for part in member.name.split("/"))):
                raise ValueError(f"Unsafe docs archive member: {member.name!r}")
            if SEMVER.fullmatch(path.parts[0]):
                raise ValueError("Top-level documentation filenames cannot be semantic versions.")
            if path.suffix == ".epub" and not served:
                raise ValueError("EPUB embeds the build time; ash_hooks publishes HTML and Markdown docs only.")
            if member.name in names:
                raise ValueError(f"Duplicate docs archive member: {member.name!r}")
            names.add(member.name)
            data = packed.extractfile(member).read()
            if member.name == "release.json":
                named = release(data, version)
            if served:
                continue
            if member.name not in source:
                raise ValueError(f"Docs archive member has no source: {member.name!r}")
            if data != source[member.name].read_bytes():
                raise ValueError(f"Docs archive bytes differ from source: {member.name!r}")
    if not {"index.html", "readme.html"} <= names:
        raise ValueError("Docs archive requires top-level index.html and readme.html.")
    if not served and names != source.keys():
        raise ValueError(f"Docs archive omits source files: {sorted(source.keys() - names)!r}")
    if named is None:
        raise ValueError("Docs archive carries no top-level release.json.")
    if served:
        named = published(named, commit, repo)
    elif named != commit:
        raise ValueError(f"release.json names {named}, not the building commit {commit}.")
    with archive.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    if served:
        print(f"DOCS OK: {len(names)} regular files served, entry pages present")
        print(f"PUBLISHED COMMIT: {named}")
    else:
        print(f"DOCS OK: {len(names)} regular files; all bytes match the source tree")
    print(f"SHA256: {digest}")
    return named


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--served", action="store_true", help="inspect an archive Hex already serves")
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True, help="the building or dispatched commit")
    parser.add_argument("--repo", type=Path, default=Path("."), help="repository for ancestry")
    parser.add_argument("archive", type=Path)
    parser.add_argument("directory", type=Path, nargs="?")
    args = parser.parse_args()
    if args.served == (args.directory is not None):
        parser.error("give a source directory, or --served without one")
    if not COMMIT.fullmatch(args.commit):
        parser.error("--commit must be a full commit SHA")
    try:
        named = check(args.archive, None if args.served else args.directory,
                      args.version, args.commit, args.repo)
    except (OSError, ValueError, tarfile.TarError) as error:
        print(f"Docs archive refused: {error}", file=sys.stderr)
        return 1
    if args.served and (output := os.environ.get("GITHUB_OUTPUT")):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"commit={named}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
