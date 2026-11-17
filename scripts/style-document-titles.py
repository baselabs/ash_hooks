#!/usr/bin/env python3
"""Use an ASCII separator in ExDoc's generated HTML page titles."""
import argparse
from pathlib import Path
import re


# ExDoc hardcodes this separator in its page and redirect templates. Match the
# last separator so an authored title remains intact for the independent check.
SEPARATOR = re.compile(rb"(<title>[^\n]*) \xe2\x80\x94 ([^\n]*</title>)")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("docs", type=Path)
    args = parser.parse_args()
    if not args.docs.is_dir():
        parser.error("the generated documentation directory does not exist")
    for path in sorted(args.docs.rglob("*.html")):
        if path.is_file():
            original = path.read_bytes()
            styled = SEPARATOR.sub(rb"\1 - \2", original)
            if styled != original:
                path.write_bytes(styled)


if __name__ == "__main__":
    main()
