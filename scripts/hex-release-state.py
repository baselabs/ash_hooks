#!/usr/bin/env python3
"""Decide whether inspected release archives are missing or already served."""

import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.request


def get(url):
    # Only transport failures and server errors are retried, at most four attempts.
    for attempt in range(4):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.status, response.read()
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
            if not 500 <= status <= 599:
                return status, b""
        except (urllib.error.URLError, http.client.HTTPException, TimeoutError, OSError):
            status = "transport error"
        if attempt < 3:
            time.sleep(2)
    raise ValueError(f"Registry lookup failed after four attempts ({status}).")


def object_body(body):
    value = json.loads(body)
    if not isinstance(value, dict):
        raise ValueError("hex.pm returned an invalid release record.")
    return value


def release_record(version):
    status, _ = get("https://hex.pm/api/packages/ash_hooks")
    if status == 404:
        raise ValueError(
            "hex.pm has no package ash_hooks; a first publication is the owner's decision"
        )
    if status != 200:
        raise ValueError(f"hex.pm answered HTTP {status} for ash_hooks; refusing.")
    status, body = get(f"https://hex.pm/api/packages/ash_hooks/releases/{version}")
    if status == 404:
        return None
    if status != 200:
        raise ValueError(f"hex.pm answered HTTP {status} for ash_hooks {version}; refusing.")
    record = object_body(body)
    if record.get("version") != version or "retirement" not in record:
        raise ValueError("hex.pm returned an incomplete or differing release record.")
    if record["retirement"] is not None:
        raise ValueError(f"hex.pm retired ash_hooks {version}; refusing.")
    return record


def sha256(path):
    with path.open("rb") as archive:
        return hashlib.file_digest(archive, "sha256").hexdigest()


def decide(record, version, package, docs):
    if record is None:
        return {"package": "upload", "docs": "upload"}
    if record.get("checksum") != sha256(package):
        raise ValueError(
            f"hex.pm serves ash_hooks {version} with other bytes; "
            "nothing replaces a published package"
        )
    if type(record.get("has_docs")) is not bool:
        raise ValueError("hex.pm returned no definite documentation state; refusing.")
    if not record["has_docs"]:
        return {"package": "served", "docs": "upload"}
    status, body = get(f"https://repo.hex.pm/docs/ash_hooks-{version}.tar.gz")
    if status != 200:
        raise ValueError(f"Docs archive lookup answered HTTP {status}; refusing.")
    if hashlib.sha256(body).hexdigest() != sha256(docs):
        raise ValueError(
            f"hex.pm serves ash_hooks {version} docs with other bytes; "
            "nothing replaces published docs"
        )
    return {"package": "served", "docs": "served"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("pre-build", "post-build"))
    parser.add_argument("version")
    parser.add_argument("--package-archive", type=Path)
    parser.add_argument("--docs-archive", type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?", args.version):
        parser.error("expected a semantic release version")
    if args.mode == "post-build":
        if not args.package_archive or not args.docs_archive:
            parser.error("post-build requires both inspected archives")
        for archive in (args.package_archive, args.docs_archive):
            if not archive.is_file() or archive.stat().st_size == 0:
                parser.error("an inspected archive is missing or empty")
    try:
        record = release_record(args.version)
        if args.mode == "pre-build":
            outputs = {"release": "missing" if record is None else "served"}
            print(f"ash_hooks {args.version}: {outputs['release']}; build may continue.")
        else:
            outputs = decide(record, args.version, args.package_archive, args.docs_archive)
            for part, state in outputs.items():
                print(f"ash_hooks {args.version} {part}: {state}")
        if output := os.environ.get("GITHUB_OUTPUT"):
            with open(output, "a", encoding="utf-8") as stream:
                for name, value in outputs.items():
                    stream.write(f"{name}={value}\n")
    except (ValueError, OSError) as error:
        # JSON errors can contain response text. Only explicit refusal messages leave.
        if isinstance(error, (json.JSONDecodeError, UnicodeDecodeError)):
            print("hex.pm returned invalid JSON; refusing.", file=sys.stderr)
        elif isinstance(error, ValueError):
            print(str(error), file=sys.stderr)
        else:
            print("Could not read an archive or write the decision; refusing.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
