#!/usr/bin/env bash
# Published-advisory check for one or more mix.lock files, failing closed.
#
#   OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY=<dir> scripts/check-advisories.sh LOCK...
#
# The OSV Hex database must already be at
# $OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY/osv-scalibr/Hex/all.zip (CI downloads
# it first, given no lock file). Each lock is read by its path, under any file
# name: Mix.Dep.Lock.read/1 takes the path, and osv-scanner takes it as
# -L mix.lock:<path>. For each lock:
#   1. the lock is exactly what Mix writes (read and rewritten through
#      Mix.Dep.Lock into a temporary file, byte-compared), so a hand edit fails;
#   2. osv-scanner runs with --offline (and, on Linux, inside a network
#      namespace with no interfaces), so nothing about the lock leaves the
#      machine;
#   3. the packages the scanner reports equal the lock's :hex and :git entries
#      as Mix counts them (the scanner reads both kinds), so a lock the scanner
#      cannot parse never passes as clean;
#   4. any advisory affecting a locked version fails. A :git entry has no
#      version, so the scanner reports every advisory filed against its
#      package name: such an entry fails closed.
set -euo pipefail

[ "$#" -ge 1 ] || { echo "usage: $0 LOCK..." >&2; exit 2; }
: "${OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY:?set to the directory holding osv-scalibr/Hex/all.zip}"
db="$OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY/osv-scalibr/Hex/all.zip"
[ -s "$db" ] || { echo "no OSV Hex database at $db" >&2; exit 2; }
scanner="${OSV_SCANNER:-osv-scanner}"

if [ "$(uname -s)" = Linux ]; then
  # no interfaces at all inside the namespace: the scan cannot reach out
  deny=(sudo env "OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY=$OSV_SCANNER_LOCAL_DB_CACHE_DIRECTORY" unshare --net --)
  scanner="$(command -v "$scanner")"
else
  deny=()
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
status=0

for lock in "$@"; do
  [ -s "$lock" ] || { echo "$lock: missing or empty" >&2; exit 2; }

  # Mix.Dep.Lock.write/2 compares against the CURRENT project's lock (and
  # skips the write when equal), then runs will_recompile, which needs a
  # project. So the rewrite runs inside a throwaway project whose own lock is
  # empty: the write always happens, and the bytes are exactly Mix's.
  path="$(cd "$(dirname "$lock")" && pwd)/$(basename "$lock")"
  rm -rf "$work/project"
  mkdir -p "$work/project"
  printf 'defmodule LockCheck.MixProject do\n  use Mix.Project\n  def project, do: [app: :lock_check, version: "0.0.0"]\nend\n' \
    > "$work/project/mix.exs"
  elixir -e '
    Mix.start()
    [source, project] = System.argv()
    lock = Mix.Dep.Lock.read(source)
    Mix.Project.in_project(:lock_check, project, fn _ ->
      Mix.Dep.Lock.write(lock, file: Path.join(project, "roundtrip.lock"))
    end)
  ' "$path" "$work/project"
  if ! cmp -s "$lock" "$work/project/roundtrip.lock"; then
    echo "$lock: not as Mix writes it (edit locks only through deps.get, deps.update or deps.unlock)" >&2
    status=1
    continue
  fi

  mix_count="$(elixir -e 'Mix.start(); [f] = System.argv(); IO.puts(Enum.count(Mix.Dep.Lock.read(f), fn {_, v} -> is_tuple(v) and elem(v, 0) in [:hex, :git] end))' "$path")"

  # the lock is read by path in the named mix.lock format, whatever its file
  # name: a lock kept as test data is never named mix.lock
  set +e
  "${deny[@]}" "$scanner" scan source --offline --format json --all-packages -L "mix.lock:$path" \
    > "$work/report.json" 2> "$work/scan.err"
  scan_status=$?
  set -e

  if ! python3 - "$work/report.json" "$mix_count" "$lock" "$scan_status" <<'PY'
import json, sys
report, expected, lock, scan_status = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
try:
    data = json.load(open(report))
except (OSError, ValueError) as error:
    print(f"{lock}: unreadable scanner report ({error}); scanner exit {scan_status}", file=sys.stderr)
    sys.exit(1)
packages = [p for r in data.get("results") or [] for p in r.get("packages") or []]
advisories = sorted(
    f'{v["id"]} {p["package"]["name"]} {p["package"]["version"]}'
    for p in packages
    for v in p.get("vulnerabilities") or []
)
failed = False
if len(packages) != expected:
    print(f"{lock}: scanner read {len(packages)} packages, Mix counts {expected} :hex and :git entries", file=sys.stderr)
    failed = True
for line in advisories:
    print(f"{lock}: advisory {line}", file=sys.stderr)
if advisories or scan_status not in (0, 1):
    failed = True
if scan_status == 1 and not advisories:
    print(f"{lock}: scanner exit 1 with no advisory in its report", file=sys.stderr)
    failed = True
if not failed:
    print(f"{lock}: {len(packages)} packages, no published advisory")
sys.exit(1 if failed else 0)
PY
  then
    sed -n '1,20p' "$work/scan.err" >&2
    status=1
  fi
done

exit "$status"
