#!/usr/bin/env bash
# Headless verification of a .livemd notebook: extracts the elixir cells
# in order (Livebook evaluates them sequentially in one session — a
# single concatenated script is the same evaluation) and runs them
# OUTSIDE any mix project (Mix.install requires it).
set -euo pipefail
notebook="${1:?usage: run-livebook.sh <notebook.livemd>}"
work="$(mktemp -d)"
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
