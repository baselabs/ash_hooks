# Publishing ash_hooks (the operator checklist)

One canonical run-sheet for a release, human-owned end to end
(the publish itself is issue #15, labeled `needs-human`).

## The surface checklist (why releases kept shipping half-done)

A release is DONE only when `mix hex.info` shows the new version AND
every surface below was either provably unchanged or provably updated —
verified by observation, never intent. `mix hex.publish docs` does NOT
touch surfaces 1 or 6.

1. hex.pm PACKAGE PAGE — renders the README baked into the newest
   release tarball; any README/metadata change needs a version bump +
   full publish (immutable per version).
2. hexdocs — built from docs() extras at publish time.
3. Livebooks — bump each notebook's "validated against" version and
   re-run `./scripts/run-livebook.sh` (step 5 below).
4. In-repo docs — README/tutorial/usage-rules/CHANGELOG version claims
   match the release being cut.
5. Tag + GitHub release.
6. `mix hex.info ash_hooks` as the FINAL step — a hidden `Proceed?
   [Yn]` prompt silently no-ops a scripted publish.

## Pre-publish (verify, in order)

1. `git status` clean; `git rev-parse HEAD` recorded; CI green on that
   SHA — all three matrix legs: Elixir 1.17/OTP 27, 1.18/OTP 27, and
   1.18/OTP 27 no-optional (there is NO 1.20 CI leg; local 1.20 gates
   below cover it).
2. Gates locally: `mix compile --warnings-as-errors && mix format --check-formatted &&
   mix credo --strict` (zero) and both test legs:
   `mix test` AND `ASH_HOOKS_NO_OPTIONAL=1 mix test`.
3. **Env guard:** `env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish ...` for
   every publish/dry-run command below. If the variable were exported,
   mix.exs would silently drop oban/plug from the hex metadata and the
   first-publish tarball is permanent. The dry-run metadata must list
   `oban (optional)` and `plug (optional)`.
4. `CHANGELOG.md`: BEFORE publishing, rename the `## Unreleased`
   section to the dated version heading and bump `@version` in
   `mix.exs` — `CHANGELOG*` ships inside the tarball, so the rename
   must not wait for post-publish.
5. Run the get-started Livebook headless
   (`./scripts/run-livebook.sh documentation/livebooks/get-started.livemd`)
   and bump the "validated against" version in its intro if needed.
6. `mix docs` builds clean; skim `doc/index.html` for the README,
   tutorial, and DSL cheat sheets rendering.
7. Name availability: `mix hex.info ash_hooks` → "No package with
   name ash_hooks" (re-verified 2026-08-22; first-publish-first-owned —
   if this now EXISTS and is not ours, STOP and escalate).
8. Dry run: run INTERACTIVELY in a terminal:
   `env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish --dry-run` — the
   numbered first-publish owner prompt asks "yourself as owner or an
   organization"; read it on screen (selection "1" is YOURSELF;
   publishing under an organization requires
   `mix hex.publish --organization <org>` instead). Decide ownership
   BEFORE this step. Expect exit 0; cosmetic "hidden module"
   doc-reference warnings are known and acceptable.
9. `mix hex.audit` clean (no retired deps in the resolved set).

## Publish (#15 — human hands on keyboard)

10. Run INTERACTIVELY in a terminal: `env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish`
   (add `--organization <org>` for org ownership). Requires
   `HEX_API_KEY` for the chosen owner. Read the prompts on screen — the
   first publish asks the OWNER selection, every publish asks
   `Proceed? [Yn]` after the code-of-conduct line. For a scripted
   publish: `printf 'y\n' | mix hex.publish ...`. To refresh ONLY the
   hexdocs site use `mix hex.publish docs`; note the hex.pm PACKAGE PAGE
   renders the README baked into the newest release TARBALL — a README
   change requires a version bump + full publish (learned on 0.1.0 →
   0.1.1).
11. Verify: `mix hex.info ash_hooks` shows the version; the docs link
   renders on hex.pm.
12. Tag: `git tag v<version> && git push origin v<version>`.

## Post-publish

13. GitHub release from the tag, summary from the CHANGELOG section.
14. Adoption coordination tickets (#12 commerce_platform, #13
    navyler_cdc) can proceed against the published version.

## Known notes

- The package ships `lib`, `.formatter.exs`, `mix.exs`, `README*`,
  `LICENSE*`, `CHANGELOG*` (see `package/0`); `documentation/` is NOT
  shipped — it feeds hexdocs via `docs()` extras, and ADRs stay on
  GitHub (the README links there).
- Optional deps (oban, plug) are marked `optional: true` in hex
  metadata; the no-optional CI leg proves the package runs without
  them (ADR-0004).
