#!/usr/bin/env bash
# Resolve a fresh production consumer and remove every artifact this check owns.
# --advisories LOCK... scans the fresh consumer lock alongside the named locks.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
consumer="$root/test/consumer"
cleanup() {
  rm -rf "$consumer/mix.lock" "$consumer/deps" "$consumer/_build"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cleanup
export MIX_ENV=prod
cd "$consumer"
mix deps.get
if [ "${1:-}" = --advisories ]; then
  shift
  cd "$root"
  scripts/check-advisories.sh "$@" "$consumer/mix.lock"
elif [ "$#" -eq 0 ]; then
  mix compile --warnings-as-errors
  mix run verify.exs
else
  echo "usage: $0 [--advisories LOCK...]" >&2
  exit 2
fi
