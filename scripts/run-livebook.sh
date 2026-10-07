#!/usr/bin/env bash
# Headless verification of a .livemd notebook: extracts the elixir cells
# in order (Livebook evaluates them sequentially in one session — a
# single concatenated script is the same evaluation) and runs them
# OUTSIDE any mix project (Mix.install requires it).
set -euo pipefail
notebook="${1:?usage: run-livebook.sh <notebook.livemd> [--archive <package.tar>]}"
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/_build"
work="$(mktemp -d "$root/_build/notebook.XXXXXX")"
trap 'rm -rf "$work"' EXIT
if [ "$#" -gt 1 ]; then
  [ "$#" -eq 3 ] && [ "$2" = "--archive" ] || { echo "invalid notebook arguments" >&2; exit 1; }
  mkdir "$work/package"
  python3 - "$3" "$work/package" <<'PY'
import hashlib, io, pathlib, sys, tarfile
archive = pathlib.Path(sys.argv[1]).resolve()
target = pathlib.Path(sys.argv[2]).resolve()
with tarfile.open(archive) as outer:
    data = outer.extractfile('contents.tar.gz').read()
with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as inner:
    for member in inner.getmembers():
        path = pathlib.PurePosixPath(member.name)
        assert not path.is_absolute() and '..' not in path.parts, 'unsafe archive path'
        assert member.isfile() or member.isdir(), 'unsupported archive member'
    inner.extractall(target, filter='data')
print(f'NOTEBOOK ARCHIVE SHA256: {hashlib.sha256(archive.read_bytes()).hexdigest()}')
PY
  export ASH_HOOKS_NOTEBOOK_SOURCE="$work/package"
else
  unset ASH_HOOKS_NOTEBOOK_SOURCE
fi
python3 - "$notebook" "$work/cells.exs" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
blocks = re.findall(r"```elixir\n(.*?)```", src, re.DOTALL)
assert blocks, "no elixir cells found"
open(sys.argv[2], "w").write("\n\n".join(blocks))
print(f"{len(blocks)} cells -> {sys.argv[2]}", file=sys.stderr)
PY
cd "$work" && elixir cells.exs
echo "NOTEBOOK OK: $notebook" >&2
