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
      grep -aFinw -- "$rule" "$path" > "$work/matches" || status=$?
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

if [ "$#" -gt 0 ]; then
  # Exercise the real scanner on disposable trees without building a package.
  [ "$1" = "--tree" ] && [ "$#" -ge 2 ] || exit 2
  shift
  find "$@" -type f -print0 | scan
else
  root="$(cd "$(dirname "$0")/.." && pwd)"
  cd "$root"
  mix hex.build --unpack --output "$work/package" > "$work/build-log" 2>&1 || exit 2
  mix docs --warnings-as-errors --output "$work/docs" > "$work/docs-log" 2>&1 || exit 2
  python3 - "$work/docs" <<'PYTHON'
from pathlib import Path
import sys
import zipfile
for path in list(Path(sys.argv[1]).rglob("*.epub")):
    # ExDoc writes this text manifest beside the actual EPUB archive.
    # It remains included in the ordinary file scan below.
    if not path.is_file() or path.name == ".build.epub":
        continue
    if not zipfile.is_zipfile(path):
        raise SystemExit(f"{path}: invalid EPUB archive ({path.stat().st_size} bytes)")
    with zipfile.ZipFile(path) as book:
        target = path.with_suffix(".epub-contents")
        for name in book.namelist():
            destination = target / name
            if not destination.resolve().is_relative_to(target.resolve()):
                raise SystemExit(2)
        book.extractall(target)
PYTHON
  {
    git ls-files -z
    find "$work/package" "$work/docs" -type f -print0
  } | scan
fi
