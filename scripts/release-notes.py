#!/usr/bin/env python3
"""Require exactly one nonempty changelog section for the release version."""

import argparse
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version")
    parser.add_argument("--changelog", type=Path, default=Path("CHANGELOG.md"))
    args = parser.parse_args()
    try:
        section(args.version, args.changelog.read_text(encoding="utf-8"))
        print(f"CHANGELOG OK: one nonempty section for {args.version}")
    except (OSError, ValueError) as error:
        print(f"Release changelog refused: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
