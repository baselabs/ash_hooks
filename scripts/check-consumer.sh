#!/usr/bin/env bash
# Compile and run the production consumer from its committed lock, then remove
# the dependencies and build output this check fetched.
set -euo pipefail
[ "$#" -eq 0 ] || { echo "usage: $0" >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"
consumer="$root/test/consumer"
version="$(elixir "$root/scripts/read-mix-version.exs" "$root/mix.exs")"
cleanup() {
  rm -rf "$consumer/deps" "$consumer/_build"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cleanup
export MIX_ENV=prod
cd "$consumer"
mix deps.get --check-locked
mix compile --warnings-as-errors
mix run verify.exs "$version"
