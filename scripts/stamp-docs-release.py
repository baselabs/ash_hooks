#!/usr/bin/env python3
"""Write release.json at the root of a built docs tree.

It names the package, the version and the commit that built the docs, so served
docs say which commit rendered them; equal package bytes do not, because docs
also render files the package does not carry, such as the docs tool's lock.
Run after the docs build and before the archive is built and inspected.
"""

import argparse
import json
from pathlib import Path
import re
import sys

PACKAGE = "ash_hooks"


def release(version, commit):
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", version):
        raise ValueError("Expected a semantic release version.")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("Expected the full commit SHA.")
    return {"package": PACKAGE, "version": version, "commit": commit}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--version", required=True)
    parser.add_argument("--commit", required=True)
    args = parser.parse_args()
    try:
        record = release(args.version, args.commit)
        if not (args.directory / "index.html").is_file():
            raise ValueError("The docs tree has no index.html; build the docs first.")
        (args.directory / "release.json").write_text(json.dumps(record) + "\n", encoding="utf-8")
    except (OSError, ValueError) as error:
        print(f"Docs release refused: {error}", file=sys.stderr)
        return 1
    print(f"release.json: {PACKAGE} {args.version} at {args.commit}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
