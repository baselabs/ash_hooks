# Publishing ash_hooks (the operator checklist)

One canonical run-sheet for a release. Everything here is human-owned:
the publish itself is issue #15 (`needs-human`) and is a STOP line for
agent sessions.

## Pre-publish (verify, in order)

1. `git status` clean; `git rev-parse HEAD` recorded; CI green on that
   SHA (all three matrix legs — 1.17, 1.18, 1.20).
2. Gates locally: `mix compile --warnings-as-errors && mix format --check-formatted &&
   mix credo --strict` (zero) and both test legs:
   `mix test` AND `ASH_HOOKS_NO_OPTIONAL=1 mix test`.
3. `CHANGELOG.md`: the release section is complete and dated; version
   bumped in `mix.exs` (`@version`).
4. `mix docs` builds clean; skim `doc/index.html` for the README,
   tutorial, and DSL cheat sheets rendering.
5. Name availability: `mix hex.info ash_hooks` → "No package with
   name ash_hooks" (re-verified 2026-08-22; first-publish-first-owned —
   if this now EXISTS and is not ours, STOP and escalate).
6. Dry run: `echo "1" | mix hex.publish --dry-run` — the piped "1"
   answers the interactive first-publish OWNER selection (choose your
   account/org deliberately; the list is printed — verify the choice).
   Expect exit 0; cosmetic "hidden module" doc-reference warnings are
   known and acceptable.
7. `mix hex.audit` clean (no retired deps in the resolved set).

## Publish (#15 — human hands on keyboard)

8. `echo "1" | mix hex.publish` (or run interactively to pick the owner
   with the arrow keys). Requires `HEX_API_KEY` for the chosen owner.
9. Verify: `mix hex.info ash_hooks` shows the version; the docs link
   renders on hex.pm.
10. Tag: `git tag v<version> && git push origin v<version>`.

## Post-publish

11. Un-pin the CHANGELOG "Unreleased" section into the version heading.
12. GitHub release from the tag, summary from the CHANGELOG section.
13. Adoption coordination tickets (#12 commerce_platform, #13
    navyler_cdc) can proceed against the published version.

## Known notes

- The package ships `lib`, `.formatter.exs`, `mix.exs`, `README*`,
  `LICENSE*`, `CHANGELOG*` (see `package/0`); `documentation/` is NOT
  shipped — it feeds hexdocs via `docs()` extras, and ADRs stay on
  GitHub (the README links there).
- Optional deps (oban, plug) are marked `optional: true` in hex
  metadata; the no-optional CI leg proves the package runs without
  them (ADR-0004).
