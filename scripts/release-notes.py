#!/usr/bin/env python3
"""Check a version's changelog section, or record a read-back release.

With only a version, the changelog must hold exactly one nonempty section for
it. With --assets and --commit, the directory must hold the package and docs
archives Hex serves; this writes SHA256SUMS and RELEASE-NOTES.md beside them.
"""

import argparse
import hashlib
from pathlib import Path
import re
import sys


def section(version, changelog):
    sections = re.findall(
        rf"^## \[{re.escape(version)}\][^\n]*\n.*?(?=^## |\Z)", changelog, re.M | re.S
    )
    body = sections[0].partition("\n")[2] if len(sections) == 1 else ""
    if not re.sub(r"^\s*#+[^\n]*$", "", body, flags=re.M).strip():
        raise ValueError(f"The changelog section for {version} is missing, duplicated or empty.")
    return sections[0].strip()


def record(version, notes, assets, commit):
    if not re.fullmatch(r"[0-9a-f]{40}", commit or ""):
        raise ValueError("Expected the full commit SHA.")
    names = (f"ash_hooks-{version}.tar", f"ash_hooks-{version}-docs.tar.gz")
    digests = []
    for name in names:
        path = assets / name
        if not path.is_file() or path.stat().st_size == 0:
            raise ValueError(f"{name} is missing or empty.")
        with path.open("rb") as stream:
            digests.append(hashlib.file_digest(stream, "sha256").hexdigest())
    (assets / "SHA256SUMS").write_text(
        "".join(f"{digest}  {name}\n" for digest, name in zip(digests, names))
    )
    (assets / "RELEASE-NOTES.md").write_text(
        f"{notes}\n\nCommit: {commit}\n\n"
        f"Package SHA-256: {digests[0]}\n\nDocs SHA-256: {digests[1]}\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    parser.add_argument("--assets", type=Path)
    parser.add_argument("--commit")
    args = parser.parse_args()
    if (args.assets is None) != (args.commit is None):
        parser.error("--assets and --commit go together")
    try:
        notes = section(args.version, args.changelog.read_text(encoding="utf-8"))
        if args.assets is None:
            print(f"CHANGELOG OK: one nonempty section for {args.version}")
        else:
            record(args.version, notes, args.assets, args.commit)
            print(f"RELEASE RECORDED: {args.assets / 'SHA256SUMS'}")
    except (OSError, ValueError) as error:
        print(f"Release notes refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
