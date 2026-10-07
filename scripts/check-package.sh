#!/usr/bin/env bash
# Build and inspect the exact candidate archive in this checkout.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
mkdir -p _build/release
version="$(python3 - <<'PY'
from pathlib import Path
import re
matches = re.findall(r'^  @version "([^"]+)"$', Path('mix.exs').read_text(), re.M)
assert len(matches) == 1, 'expected exactly one Mix project version'
print(matches[0])
PY
)"
archive="$root/_build/release/ash_hooks-$version.tar"
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = "--inspect" ] || { echo "usage: check-package.sh [--inspect <archive>]" >&2; exit 1; }
  archive="$2"
else
  env -u ASH_HOOKS_NO_OPTIONAL mix hex.build --output "$archive"
fi
python3 - "$archive" "$version" <<'PY'
import hashlib, io, pathlib, posixpath, re, sys, tarfile
from urllib.parse import unquote, urlsplit
archive = pathlib.Path(sys.argv[1])
with tarfile.open(archive) as outer:
    content = outer.extractfile('contents.tar.gz').read()
    metadata = outer.extractfile('metadata.config').read().decode()
assert '{<<"version">>,<<"' + sys.argv[2] + '">>}' in metadata, 'package version mismatch'
requirements = dict(re.findall(r'\[\{<<"name">>,<<"([^\"]+)">>\},(.*?)\}\]', metadata, re.S))
for name in ['oban', 'plug']:
    assert name in requirements, f'optional requirement missing: {name}'
    assert '{<<"optional">>,true}' in requirements[name], f'requirement not optional: {name}'
with tarfile.open(fileobj=io.BytesIO(content), mode='r:gz') as inner:
    names = set(inner.getnames())
    required = {
        'README.md', 'CHANGELOG.md', 'usage-rules.md', 'UPGRADING.md',
        'SECURITY.md', 'CONTRIBUTING.md', 'LICENSE',
        'documentation/tutorials/get-started.md',
        'documentation/tutorials/tenancy-adoption-checklist.md',
        'documentation/livebooks/get-started.livemd',
        'documentation/dsls/DSL-AshHooks.md',
        'documentation/dsls/DSL-AshHooks.Endpoint.md',
        'documentation/dsls/DSL-AshHooks.Subscription.md',
        'documentation/dsls/DSL-AshHooks.InboundDelivery.md',
        'documentation/dsls/DSL-AshHooks.OutboundDelivery.md',
    }
    assert required <= names, f'missing package surfaces: {sorted(required - names)}'
    assert not any('.DS_Store' in name for name in names), 'OS metadata in archive'
    checked_links = 0
    for member in inner.getmembers():
        if member.isfile() and member.name.endswith(('.md', '.livemd')):
            document = inner.extractfile(member).read().decode()
            for target in re.findall(r'!?\[[^\]]*\]\(([^\s)]+)(?:\s+"[^"]*")?\)', document):
                parsed = urlsplit(target.strip('<>'))
                if parsed.scheme or parsed.netloc or not parsed.path:
                    continue
                linked = posixpath.normpath(posixpath.join(posixpath.dirname(member.name), unquote(parsed.path)))
                assert linked in names, f'package documentation link missing: {member.name} -> {target}'
                checked_links += 1
    assert checked_links > 0, 'relative documentation link instrument saw no known links'
    for member in inner.getmembers():
        path = pathlib.PurePosixPath(member.name)
        assert not path.is_absolute() and '..' not in path.parts, 'unsafe archive path'
        assert member.isfile() or member.isdir(), 'unsupported archive member'
        if member.isfile():
            source = pathlib.Path(member.name)
            assert source.is_file(), f'archive source not in checkout: {source}'
            assert inner.extractfile(member).read() == source.read_bytes(), f'archive source mismatch: {source}'
print(f'PACKAGE OK: {len(names)} archive entries; {checked_links} relative documentation links; all bytes match checkout')
print(f'ARCHIVE: {archive}')
print(f'SHA256: {hashlib.sha256(archive.read_bytes()).hexdigest()}')
PY
