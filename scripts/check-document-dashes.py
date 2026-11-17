#!/usr/bin/env python3
"""Check only the Hex archive and generated HTML/EPUB publication surfaces."""
import argparse
import html
import io
import re
import subprocess
from pathlib import Path
import tarfile
import zipfile


def lines(path, content):
    return [
        f"{path}:{number}"
        for number, line in enumerate(content.split(b"\n"), 1)
        if b"\xe2\x80\x93" in line or b"\xe2\x80\x94" in line
    ]


def build_identity():
    # Read the same project configuration as the docs build without compiling
    # or starting the application. Candidate HTML cannot supply its own identity.
    expression = (
        "config = Mix.Project.config(); "
        'IO.write((config[:name] || Atom.to_string(config[:app])) <> " v" <> config[:version])'
    )
    result = subprocess.run(
        ["mix", "run", "--no-start", "--no-compile", "--no-deps-check", "-e", expression],
        check=True,
        capture_output=True,
    )
    return html.escape(result.stdout.decode("utf-8")).encode("utf-8")


def authored_html(content, identity):
    # Only ExDoc's final page separator or exact redirect title separator is
    # outside authored text. Keep every other title and body byte in the scan.
    separator = b" \xe2\x80\x94 "
    suffix = separator + identity
    redirect = identity + separator + b"Documentation"

    def title(match):
        text = match.group(1)
        if text.endswith(suffix):
            text = text[:-len(suffix)] + b" " + identity
        elif text == redirect:
            text = identity + b" Documentation"
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
        identity = build_identity()
        for path in sorted(Path(docs).rglob("*")):
            if not path.is_file():
                continue
            if path.suffix == ".html":
                offenses.extend(lines(path, authored_html(path.read_bytes(), identity)))
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
