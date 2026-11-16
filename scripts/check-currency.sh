#!/usr/bin/env bash
# Currency check: the repo's dependency state is mechanical, not remembered.
#
#   * FAILS (exit 1) whenever `mix hex.outdated` shows resolver-updatable
#     drift — anything "Update possible" must be updated now, not parked.
#
set -uo pipefail

echo "== mix hex.outdated =="
outdated_out="$(mix hex.outdated 2>&1)"
printf '%s\n' "$outdated_out" | grep -v 'authentication session\|hex\.user auth'

# Fail closed: if hex.outdated errored (lock mismatch, resolver failure,
# network) it prints no report — "no Update possible found" in that output
# is an instrument failure, not currency.
if ! printf '%s\n' "$outdated_out" | grep -q '^Dependency'; then
  echo
  echo "CURRENCY: FAIL — mix hex.outdated produced no report (see above)."
  exit 1
fi

if printf '%s\n' "$outdated_out" | grep -q 'Update possible'; then
  echo
  echo "CURRENCY: FAIL — resolver-updatable drift above. Update it now:"
  echo "  mix deps.update <names>    (then re-run: mix hex.audit)"
  exit 1
fi

echo
echo "CURRENCY: OK — no resolver-updatable package is out of date."
echo "== Latest releases outside the declared requirements =="

rejected="$(printf '%s\n' "$outdated_out" | awk '
  /^Dependency/ { intable = 1; next }
  intable && /^-+$/ { next }
  intable && /^[^[:space:]]/ {
    # Parse from the right: the Status column is last ("Up-to-date" or
    # "Update possible"); Current and Latest precede it. The optional
    # Only column (dev, dev,test) sits between name and Current and may
    # or may not contain a comma, so left-parsing is unreliable.
    name = $1
    if ($(NF - 1) == "Update" && $NF == "possible") {
      status = "Update possible"; latest = $(NF - 2); current = $(NF - 3)
    } else {
      status = $NF; latest = $(NF - 1); current = $(NF - 2)
    }
    if (current != latest && status != "Update possible")
      print name, current, latest
  }
  intable && /^[[:space:]]*$/ { intable = 0 }
')"

if [ -z "$rejected" ]; then
  echo "   (none — every package is at its latest release)"
  exit 0
fi

while read -r name current latest; do
  echo "  ${name}: locked ${current}, latest ${latest}"
  grep -n "{:${name}," mix.exs | sed 's/^/    mix.exs: /'
done <<EOF
$rejected
EOF

exit 0
