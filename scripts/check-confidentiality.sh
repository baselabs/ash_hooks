#!/usr/bin/env bash
# The private vocabulary is supplied only by the caller's environment.
set -euo pipefail
export LC_ALL=C
[ -n "${PUBLIC_DOCS_DENYLIST:-}" ] || exit 2
work="$(mktemp -d "${TMPDIR:-/tmp}/ash_hooks-confidentiality.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
printf '%s\n' "$PUBLIC_DOCS_DENYLIST" > "$work/rules"
# Empty rules would match every line and cannot define a useful policy.
if grep -q '^[[:space:]]*$' "$work/rules"; then exit 2; fi

scan() {
  local path rule number status found=0
  while IFS= read -r -d '' path; do
    number=0
    while IFS= read -r rule; do
      number=$((number + 1))
      status=0
      # The rule reaches grep through a file, never its arguments, so process
      # listings and audit logs cannot show it. printf is a shell builtin.
      printf '%s\n' "$rule" > "$work/rule"
      grep -aFinw -f "$work/rule" -- "$path" > "$work/matches" 2>/dev/null || status=$?
      if [ "$status" -gt 1 ]; then return 2; fi
      if [ "$status" -eq 0 ]; then
        # Only line numbers leave the private match file.
        while IFS=: read -r line _; do
          printf '%s:%s rule-%s\n' "$path" "$line" "$number"
        done < "$work/matches"
        found=1
      fi
    done < "$work/rules"
  done
  return "$found"
}

# The same scanner must see its own known hit before any candidate is scanned.
IFS= read -r first < "$work/rules"
printf '%s\n' "$first" > "$work/control"
control_status=0
printf '%s\0' "$work/control" | scan > "$work/control-result" || control_status=$?
[ "$control_status" -eq 1 ] || exit 2
grep -Fxq "$work/control:1 rule-1" "$work/control-result" || exit 2

tracked=0
if [ "${1:-}" = "--tree" ]; then
  # Exercise the real scanner on disposable trees without building a package.
  [ "$#" -ge 2 ] || exit 2
  shift
  find "$@" -type f -print0 | scan
  exit "$?"
elif [ "${1:-}" = "--publication" ]; then
  # Already built surfaces let the same publication path run on real fixtures.
  [ "$#" -eq 3 ] && [ -d "$2" ] && [ -d "$3" ] || exit 2
  package="$2"
  docs="$3"
else
  [ "$#" -eq 0 ] || exit 2
  root="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$root"
  package="$work/package"
  docs="$work/docs"
  mix hex.build --unpack --output "$package" > "$work/build-log" 2>&1 || exit 2
  mix docs --warnings-as-errors --output "$docs" > "$work/docs-log" 2>&1 || exit 2
  tracked=1
fi

# ExDoc's scripts, fonts and stylesheets are containers for its own code, not
# authored text. Scan the pages it renders from the docs: HTML, Markdown and
# llms.txt.
{
  if [ "$tracked" -eq 1 ]; then git ls-files -z; fi
  find "$package" -type f -print0
  find "$docs" -type f \( -name '*.html' -o -name '*.md' -o -name '*.txt' \) -print0
} | scan
