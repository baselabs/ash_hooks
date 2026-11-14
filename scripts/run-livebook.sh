#!/usr/bin/env bash
# Headless verification of a .livemd notebook: extracts the elixir cells in
# order (Livebook evaluates them sequentially in one session; one concatenated
# script is the same evaluation) and runs them OUTSIDE any mix project
# (Mix.install requires it) and outside the checkout. The notebook runs
# exactly as written.
#
#   run-livebook.sh <notebook.livemd>
#       Resolves every package from hex.pm, as a reader's machine does.
#
#   run-livebook.sh <notebook.livemd> --archive <package.tar>
#       Resolves the notebook's unmodified Mix.install against a throwaway
#       local Hex registry that serves the candidate archive and the exact
#       hex.pm tarballs of its dependency graph, signed with a throwaway key.
#       Hex verifies each tarball's checksum against that registry, as it does
#       for a published release. Everything is removed on exit.
set -euo pipefail
notebook="$(cd "$(dirname "${1:?usage: run-livebook.sh <notebook.livemd> [--archive <package.tar>]}")" && pwd)/$(basename "$1")"
# The notebook runs from a directory outside the checkout, as a reader's does:
# a cell that reads a path relative to the repository fails here instead of
# passing only because the checkout happened to be the working directory.
root="$(cd "$(dirname "$0")/.." && pwd)"
work="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/ash_hooks-notebook.XXXXXX")" && pwd -P)"
case "$work/" in
  "$(cd "$root" && pwd -P)"/*) echo "the notebook work directory must be outside the checkout: $work" >&2; rm -rf "$work"; exit 1 ;;
esac
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT

python3 - "$notebook" "$work/cells.exs" "$work/install.exs" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
blocks = re.findall(r"```elixir\n(.*?)```", src, re.DOTALL)
assert blocks, "no elixir cells found"
open(sys.argv[2], "w").write("\n\n".join(blocks))
install = [b for b in blocks if "Mix.install(" in b]
assert len(install) == 1, "the notebook must have exactly one Mix.install cell"
open(sys.argv[3], "w").write(install[0])
print(f"{len(blocks)} cells -> {sys.argv[2]}", file=sys.stderr)
PY

if [ "$#" -gt 1 ]; then
  [ "$#" -eq 3 ] && [ "$2" = "--archive" ] || { echo "invalid notebook arguments" >&2; exit 1; }
  archive="$(cd "$(dirname "$3")" && pwd)/$(basename "$3")"
  registry="$work/registry"
  mkdir -p "$work/candidate" "$work/probe" "$registry/tarballs"

  # The candidate's name and version, and its unpacked contents for the probe.
  read -r name version < <(python3 - "$archive" "$work/candidate" <<'PY'
import io, pathlib, re, sys, tarfile
archive, target = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with tarfile.open(archive) as outer:
    metadata = outer.extractfile('metadata.config').read().decode()
    data = outer.extractfile('contents.tar.gz').read()
with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as inner:
    for member in inner.getmembers():
        path = pathlib.PurePosixPath(member.name)
        assert not path.is_absolute() and '..' not in path.parts, 'unsafe archive path'
        assert member.isfile() or member.isdir(), 'unsupported archive member'
    inner.extractall(target, filter='data')
(target / 'hex_metadata.config').write_text(metadata)
name = re.search(r'\{<<"name">>,<<"([^"]+)">>\}', metadata).group(1)
version = re.search(r'\{<<"version">>,<<"([^"]+)">>\}', metadata).group(1)
assert archive.name == f'{name}-{version}.tar', f'archive name does not match its metadata: {archive.name}'
print(name, version)
PY
)

  # Resolve the notebook's own dependency list once against hex.pm, with the
  # candidate supplied from its unpacked contents, to learn the exact graph.
  cat > "$work/probe.exs" <<'EXS'
[install, name, version, candidate] = System.argv()
name = String.to_atom(name)
{:ok, ast} = Code.string_to_quoted(File.read!(install))
{_, found} =
  Macro.prewalk(ast, [], fn
    {{:., _, [{:__aliases__, _, [:Mix]}, :install]}, _, [deps | _]} = node, acc -> {node, [deps | acc]}
    node, acc -> {node, acc}
  end)
[deps_ast] = found
{deps, _} = Code.eval_quoted(deps_ast)
{^name, requirement} = List.keyfind(deps, name, 0) || raise "the Mix.install cell does not install #{name}"
true = Version.match?(version, requirement) || raise "#{requirement} does not admit candidate #{version}"
deps = List.keyreplace(deps, name, 0, {name, path: candidate})
File.write!("mix.exs", """
defmodule NotebookProbe.MixProject do
  use Mix.Project
  def project, do: [app: :notebook_probe, version: "0.0.0", deps: #{inspect(deps, limit: :infinity)}]
end
""")
EXS
  (cd "$work/probe" && elixir "$work/probe.exs" "$work/install.exs" "$name" "$version" "$work/candidate" && mix deps.get >/dev/null)

  # Every hex.pm tarball in that graph, then the candidate itself.
  elixir -e '
    lock = System.argv() |> hd() |> File.read!() |> Code.string_to_quoted!(emit_warnings: false) |> Code.eval_quoted() |> elem(0)
    for {_, {:hex, pkg, ver, _, _, _, "hexpm", _}} <- lock, do: IO.puts("#{pkg} #{ver}")
  ' "$work/probe/mix.lock" > "$work/graph.txt"
  [ -s "$work/graph.txt" ] || { echo "empty dependency graph" >&2; exit 1; }
  (cd "$registry/tarballs" && while read -r pkg ver; do mix hex.package fetch "$pkg" "$ver" >/dev/null; done < "$work/graph.txt")
  cp "$archive" "$registry/tarballs/"

  # A registry named hexpm, so the cell's unqualified requirements resolve
  # from it, signed by a key that exists only for this run.
  openssl genrsa -out "$work/registry.pem" 2048 2>/dev/null
  (cd "$work" && mix hex.registry build registry --name=hexpm --private-key=registry.pem >/dev/null)
  port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  python3 -m http.server "$port" --bind 127.0.0.1 --directory "$registry" >/dev/null 2>&1 &
  server_pid=$!
  curl --silent --fail --retry 20 --retry-connrefused --retry-delay 1 "http://127.0.0.1:$port/names" >/dev/null

  export HEX_HOME="$work/hex"
  export MIX_INSTALL_DIR="$work/install"
  mix hex.repo set hexpm --url "http://127.0.0.1:$port" --public-key "$registry/public_key" >/dev/null
  echo "NOTEBOOK ARCHIVE SHA256: $(shasum -a 256 "$archive" | cut -d' ' -f1)" >&2
fi

cd "$work" && elixir cells.exs

if [ "$#" -gt 1 ]; then
  # The package Mix.install compiled is the candidate, byte for byte.
  installed="$(find "$MIX_INSTALL_DIR" -path "*/deps/$name/.hex" -print -quit)"
  [ -n "$installed" ] || { echo "no installed $name found" >&2; exit 1; }
  elixir -e '
    [hex, archive, version] = System.argv()
    {{:hex, _, _}, meta} = :erlang.binary_to_term(File.read!(hex))
    expected = Base.encode16(:crypto.hash(:sha256, File.read!(archive)), case: :lower)
    (meta[:outer_checksum] == expected and meta[:version] == version) ||
      raise "installed package #{inspect(meta)} is not the candidate (#{expected})"
  ' "$installed" "$archive" "$version"
  echo "NOTEBOOK INSTALLED THE CANDIDATE: $name $version" >&2
fi
echo "NOTEBOOK OK: $notebook" >&2
