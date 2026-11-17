#!/usr/bin/env python3
"""Check only the Hex archive and generated HTML/EPUB publication surfaces."""
import argparse
import io
import re
from pathlib import Path
import tarfile
import zipfile


def lines(path, content):
    return [
        f"{path}:{number}"
        for number, line in enumerate(content.split(b"\n"), 1)
        if b"\xe2\x80\x93" in line or b"\xe2\x80\x94" in line
    ]


def authored_html(content):
    # ExDoc supplies the project identity and the final title separator. Only
    # that exact separator is outside authored text; titles and bodies stay strict.
    project = re.search(rb'<meta name="project" content="([^"<>]+ v[0-9][^"<>]*)">', content)
    if not project:
        return content
    suffix = b" \xe2\x80\x94 " + project.group(1)

    def title(match):
        text = match.group(1)
        if text.endswith(suffix):
            text = text[:-len(suffix)] + b" " + project.group(1)
        return b"<title>" + text + b"</title>"

    return re.sub(rb"<title>([^<>\n]*)</title>", title, content)


def check(package=None, docs=None):
    offenses = []
    if package:
        with tarfile.open(package) as outer:
            contents = outer.extractfile("contents.tar.gz").read()
        with tarfile.open(fileobj=io.BytesIO(contents), mode="r:gz") as inner:
            for member in inner.getmembers():
                if member.isfile():
                    offenses.extend(lines(member.name, inner.extractfile(member).read()))
    if docs:
        for path in sorted(Path(docs).rglob("*")):
            if not path.is_file():
                continue
            if path.suffix == ".html":
                offenses.extend(lines(path, authored_html(path.read_bytes())))
            elif path.suffix == ".epub":
                if path.name == ".build.epub":
                    offenses.extend(lines(path, path.read_bytes()))
                    continue
                with zipfile.ZipFile(path) as book:
                    for name in book.namelist():
                        offenses.extend(lines(f"{path}/{name}", book.read(name)))
    return sorted(set(offenses))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package")
    parser.add_argument("--docs")
    args = parser.parse_args()
    if not args.package and not args.docs:
        parser.error("provide --package or --docs")
    offenses = check(args.package, args.docs)
    for offense in offenses:
        print(offense)
    return bool(offenses)


if __name__ == "__main__":
    raise SystemExit(main())
