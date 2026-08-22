# Publishing ash_hooks (the operator checklist)

One canonical run-sheet for a release, human-owned end to end.

## The surface checklist (why releases kept shipping half-done)

A release is DONE only when `mix hex.info ash_hooks` shows the new version AND
every surface below was either provably unchanged or provably updated —
verified by observation, never intent. `mix hex.publish docs` does NOT
touch surfaces 1 or 6.

1. hex.pm PACKAGE PAGE — renders the README baked into the newest release
   tarball; any README/metadata change needs a version bump + full publish
   (immutable per version).
2. hexdocs — built from docs() extras at publish time.
3. Livebooks — bump each notebook's "validated against" version and
   re-run `./scripts/run-livebook.sh` (step 6 below).
4. In-repo docs — usage-rules.md, SECURITY.md, CONTRIBUTING.md,
   UPGRADING.md, README, tutorial, CHANGELOG: grep the release diff for
   every surface that references a version or claims currency; each must
   match the release being cut. **Install constraints in code examples
   (`{:ash_hooks, "~> X.Y"}` in README + tutorial) are part of this
   sweep** — they rot silently every minor.
5. DSL cheat sheets — the CI `package` leg runs
   `mix spark.cheat_sheets --check` (committed sheets must match the
   DSL); if it reds, regenerate with `mix spark.cheat_sheets` and commit
   the result alongside the DSL change.
6. Tag + GitHub release.
7. `mix hex.info ash_hooks` as the FINAL step — a hidden `Proceed?
   [Yn]` prompt silently no-ops a scripted publish.

## Pre-publish (verify, in order)

1. `git status` clean; `git rev-parse HEAD` recorded; CI green on that
   SHA — ALL legs: the matrix (1.17/27, 1.18/27, 1.18/27 no-optional),
   floor (1.17/27, lock-free), dialyzer, package (tarball + docs), and
   livebook.
2. Gates locally: `mix compile --warnings-as-errors && mix format --check-formatted &&
   mix credo --strict` (zero), `mix dialyzer` (zero), and both test legs:
   `mix test` AND `ASH_HOOKS_NO_OPTIONAL=1 mix test`.
3. **Env guard:** `env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish ...` for
   every publish/dry-run command below. If the variable were exported,
   mix.exs would silently drop oban/plug from the hex metadata and a
   published tarball is permanent. The dry-run metadata must list
   `oban (optional)` and `plug (optional)`.
4. `CHANGELOG.md`: rename the `## Unreleased` section to the dated
   version heading and bump `@version` in `mix.exs` — `CHANGELOG*` ships
   inside the tarball, so the rename must not wait for post-publish.
   Keep a fresh empty `## Unreleased` section behind it.
5. Version-currency sweep (surface checklist items 3–5): livebook
   "validated against" pin, install constraints in README + tutorial,
   cheat sheets regenerated, any doc line naming the previous version.
6. Run the get-started Livebook headless
   (`./scripts/run-livebook.sh documentation/livebooks/get-started.livemd`).
   NOTE the ordering: a version-bumped notebook `Mix.install` can only
   resolve against hex AFTER the release lands — on the release SHA the
   local run and the CI livebook leg are expected to fail until the
   publish; publish, then re-run both.
7. `mix docs` builds clean; skim `doc/index.html` for the README,
   tutorial, and DSL cheat sheets rendering.
8. Ownership sanity: `mix hex.info ash_hooks` must show OUR releases
   (latest = the previous version). If it shows a package that is not
   ours, STOP and escalate (first-publish ownership is long settled —
   this step exists for exactly the failure it names).
9. Dry run: `env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish --dry-run`.
   Expect exit 0; cosmetic "hidden module" doc-reference warnings are
   known and acceptable.
10. `mix hex.audit` clean (no retired deps in the resolved set).

## Major releases (the 1.0.0+ case)

A MAJOR bump additionally owes (ADR-0010):

- The semver/stability statement is current in the README.
- UPGRADING.md carries the migration notes from the previous major.
- The support matrix (Elixir/OTP/Ash floors) matches the CI floor leg.
- Deprecations removed this major ran their two-minor notice window.

## Publish

11. Run INTERACTIVELY in a terminal: `env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish`
    (first-publish owner selection is long done; every publish asks
    `Proceed? [Yn]` after the code-of-conduct line). For a scripted
    publish: `printf 'y\n' | mix hex.publish ...`. To refresh ONLY the
    hexdocs site use `mix hex.publish docs`; the hex.pm PACKAGE PAGE
    renders the README baked into the newest release TARBALL — a README
    change requires a version bump + full publish.
12. Verify: `mix hex.info ash_hooks` shows the version; the docs link
    renders on hex.pm; the package page README shows the new content.
13. Tag: `git tag v<version> && git push origin main v<version>`.

## Post-publish

14. GitHub release from the tag, summary from the CHANGELOG section.
15. Adoption coordination issues proceed against the published version.

## Known notes

- The package ships `lib`, `.formatter.exs`, `mix.exs`, `README*`,
  `LICENSE*`, `CHANGELOG*`, `usage-rules*`, `SECURITY*`, `CONTRIBUTING*`,
  `UPGRADING*` (see `package/0`); `documentation/` is NOT shipped — it
  feeds hexdocs via `docs()` extras, and ADRs stay on GitHub (the README
  links there). The CI `package` leg asserts the tarball carries the
  publish surfaces mechanically.
- Optional deps (oban, plug) are marked `optional: true` in hex
  metadata; the no-optional CI leg proves the package runs without them
  (ADR-0004).
