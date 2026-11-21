#!/usr/bin/env python3
"""Read the platform engine and declared PostgreSQL compatibility lanes."""

import argparse
import json
from pathlib import Path
import re
import sys


ENGINE_REF = re.compile(
    r"ghcr\.io/baselabs/postgres:([0-9]+)\.[0-9]+-inputs-[0-9a-f]{64}"
    r"@sha256:[0-9a-f]{64}"
)
LANE_IMAGE = re.compile(
    r"postgres:([0-9]+)(?:-[A-Za-z0-9_][A-Za-z0-9_.-]*)?@sha256:[0-9a-f]{64}"
)


def parse_lanes(engine_ref, declaration):
    engine = ENGINE_REF.fullmatch(engine_ref[:-1]) if engine_ref.endswith("\n") else None
    if not engine:
        raise ValueError("engine reference must be one digest-pinned platform image line with a trailing newline")
    engine_major = int(engine[1])
    lanes = {}
    seen = set()
    for number, line in enumerate(declaration.splitlines(), 1):
        fields = line.partition("#")[0].split()
        if not fields:
            continue
        if len(fields) != 2:
            raise ValueError(f"line {number}: expected <major> <image>")
        major, image = fields
        if not re.fullmatch(r"[0-9]+", major):
            raise ValueError(f"line {number}: major must contain only digits")
        match = LANE_IMAGE.fullmatch(image)
        if not match or match[1] != major:
            raise ValueError(f"line {number}: expected a digest-pinned postgres image tagged with major {major}")
        if int(major) in seen:
            raise ValueError(f"line {number}: duplicate major {major}")
        if int(major) == engine_major:
            raise ValueError(f"line {number}: major {major} is already covered by the platform engine")
        seen.add(int(major))
        lanes[major] = image
    return lanes


def matrix(lanes):
    include = [{"lane": "engine"}] + [{"lane": major} for major in lanes]
    return "postgres_matrix=" + json.dumps({"include": include}, separators=(",", ":"))


def image_for(lanes, major):
    if major not in lanes:
        raise ValueError(f"undeclared compatibility major {major}")
    return lanes[major]


def self_test():
    engine = "ghcr.io/baselabs/postgres:90.1-inputs-" + "a" * 64 + "@sha256:" + "b" * 64 + "\n"
    image = "postgres:91-alpine@sha256:" + "c" * 64
    other_image = "postgres:92@sha256:" + "d" * 64
    declaration = f"91 {image}\n92 {other_image}\n"
    cases = [
        ("declared lanes", engine, declaration, {"91": image, "92": other_image}),
        ("comments, blanks and CRLF", engine, f"# lanes\r\n\r\n  91 {image} # test\r\n", {"91": image}),
        ("empty declaration", engine, "", {}),
        ("variant tag", engine, declaration.replace("-alpine", "-alpine3.23"),
         {"91": image.replace("-alpine", "-alpine3.23"), "92": other_image}),
        ("engine major in lanes", engine, "90 postgres:90@sha256:" + "c" * 64,
         "line 1: major 90 is already covered by the platform engine"),
        ("engine major derived from ref", engine.replace(":90.", ":91."), declaration,
         "line 1: major 91 is already covered by the platform engine"),
        ("engine major with leading zero", engine, "090 postgres:090@sha256:" + "c" * 64,
         "line 1: major 090 is already covered by the platform engine"),
        ("duplicate major", engine, declaration + f"91 {image}\n", "line 3: duplicate major 91"),
        ("duplicate major with leading zero", engine, f"91 {image}\n091 postgres:091@sha256:" + "c" * 64,
         "line 2: duplicate major 091"),
        ("missing image", engine, "91\n", "line 1: expected <major> <image>"),
        ("extra field", engine, f"91 {image} extra\n", "line 1: expected <major> <image>"),
        ("nonnumeric major", engine, f"latest {image}\n", "line 1: major must contain only digits"),
        ("non-ASCII digits", engine, f"\u0669\u0661 {image}\n", "line 1: major must contain only digits"),
    ]
    bad_images = {
        "tag major mismatch": image.replace(":91-", ":92-"),
        "missing digest": "postgres:91-alpine",
        "short digest": image[:-1],
        "uppercase digest": image.replace("c" * 64, "C" * 64),
        "foreign registry": "example.com/" + image,
        "missing tag": "postgres@sha256:" + "c" * 64,
        "minor tag": image.replace(":91-", ":91.1-"),
        "empty variant": image.replace("-alpine", "-"),
        "invalid variant": image.replace("-alpine", "-bad/variant"),
    }
    for label, bad_image in bad_images.items():
        cases.append((label, engine, f"91 {bad_image}\n",
                      "line 1: expected a digest-pinned postgres image tagged with major 91"))
    bad_engines = {
        "missing engine newline": engine[:-1],
        "extra engine newline": engine + "\n",
        "multiple engine lines": engine + engine,
        "engine CRLF": engine.replace("\n", "\r\n"),
        "foreign engine registry": engine.replace("ghcr.io", "example.com"),
        "missing engine minor": engine.replace("90.1", "90"),
        "short engine inputs": engine.replace("a" * 64, "a" * 63),
        "short engine digest": engine.replace("b" * 64, "b" * 63),
        "uppercase engine digest": engine.replace("b" * 64, "B" * 64),
        "engine whitespace": " " + engine,
    }
    for label, bad_engine in bad_engines.items():
        cases.append((label, bad_engine, declaration,
                      "engine reference must be one digest-pinned platform image line with a trailing newline"))
    for label, engine_ref, contents, expected in cases:
        try:
            actual = parse_lanes(engine_ref, contents)
        except ValueError as error:
            actual = str(error)
        if actual != expected:
            raise ValueError(f"self-test {label}: expected {expected!r}, got {actual!r}")
        print(f"ok: {label}")

    lanes = parse_lanes(engine, declaration)
    expected_matrix = 'postgres_matrix={"include":[{"lane":"engine"},{"lane":"91"},{"lane":"92"}]}'
    if matrix(lanes) != expected_matrix or image_for(lanes, "91") != image:
        raise ValueError("self-test: matrix or image output differs")
    try:
        image_for(lanes, "engine")
    except ValueError as error:
        if str(error) != "undeclared compatibility major engine":
            raise
    else:
        raise ValueError("self-test: undeclared compatibility major was accepted")
    print(f"postgres-lanes self-test: {len(cases) + 3} cases passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--engine-ref", type=Path, default=Path(".github/postgres.ref"))
    parser.add_argument("--lanes", type=Path, default=Path(".github/postgres-lanes"))
    commands = parser.add_subparsers(dest="command")
    commands.add_parser("matrix", help="print the PostgreSQL matrix as a GitHub output")
    image = commands.add_parser("image", help="print a declared compatibility image")
    image.add_argument("major")
    args = parser.parse_args()
    if args.self_test and args.command:
        parser.error("--self-test cannot be combined with a subcommand")
    if not args.self_test and not args.command:
        parser.error("provide matrix, image <major>, or --self-test")
    try:
        if args.self_test:
            self_test()
            return 0
        lanes = parse_lanes(args.engine_ref.read_bytes().decode("utf-8"), args.lanes.read_text(encoding="utf-8"))
        print(matrix(lanes) if args.command == "matrix" else image_for(lanes, args.major))
        return 0
    except (OSError, UnicodeError, ValueError) as error:
        print(f"postgres-lanes: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
