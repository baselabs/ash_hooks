# Publishing ash_hooks

A release includes the Hex package, versioned API docs, executable Livebook,
and matching GitHub source and release notes. This checklist is the canonical
operator procedure.

## Prepare the release

1. Choose the version under [ADR-0010](adr/0010-semver-and-support-policy.md).
   Update `mix.exs`, dated CHANGELOG, install constraints, supported floors,
   upgrade guidance, and every notebook's exact package pin. Keep a fresh
   `Unreleased` section. Review README and tutorials for a new reader, then
   check their examples and contracts against the final implementation.
2. Regenerate the five DSL references:

   ```sh
   mix spark.cheat_sheets --extensions AshHooks,AshHooks.Endpoint,AshHooks.Subscription,AshHooks.InboundDelivery,AshHooks.OutboundDelivery
   ```

3. Complete the independent review and resolve its confirmed product findings.
   Run the declared checks on the final source: warnings-as-errors compilation,
   formatting, strict Credo, tests, 100% of the declared Mix coverage surface, the no-optional
   test leg, Dialyzer, dependency currency, and `mix hex.audit`. Run the real
   PostgreSQL qualification and minimal production consumer, including Ash's
   exact supported floor. CONTRIBUTING describes service setup and commands.
   Run the 100% coverage command with PostgreSQL and the real receiver available.
   The opt-in floor worker check uses Httpbun; it requires `ASH_HOOKS_HTTPBUN=1`.
4. Build and inspect the candidate archive. This checks required documentation,
   optional dependency metadata, safe paths, and byte equality with the checkout:

   ```sh
   ./scripts/check-package.sh
   mix docs --warnings-as-errors
   ```

   Resolve every ExDoc warning. Inspect rendered README, tutorial, upgrade guide,
   API links, and generated DSL pages. Never ignore a broken reference as cosmetic.
5. Execute each notebook against that candidate archive before publishing:

   ```sh
   ./scripts/run-livebook.sh documentation/livebooks/get-started.livemd --archive _build/release/ash_hooks-2.0.1.tar
   ```

   The runner supplies the unpacked archive explicitly inside this checkout.
   Normal notebook execution uses the exact registry version. Both paths are
   required; this removes the publication/CI dependency loop. The existing real
   receiver must answer on `LOCAL_WEBHOOK_TESTER_PORT` (default 52871); do not
   start a second receiver to replace an unavailable service.
6. Record the final source commit and archive digest. Commit the reviewed source,
   push `v<version>` to run release-candidate CI, and verify every job plus
   `all-checks-pass` on that exact commit. Required checks on `main` must enforce
   that aggregate status. Push the same verified commit to `main`; confirm its
   authoritative SHA and CI status before publishing.
7. Dry-run the full publication with optional dependency metadata enabled:

   ```sh
   env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish --dry-run
   ```

   Inspect its version, package name, file list, and `oban`/`plug` optional flags.
   Confirm the current Hex package belongs to the maintainer account.

## Publish and verify

Use the project's gitignored `.env`; never print or copy the key value:

```sh
set -a
source .env
set +a
env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish --yes
```

A full publish updates both package and documentation. A docs-only publish cannot
update the README baked into an immutable package archive.

After publication:

1. Read the release through Hex's API and `mix hex.info ash_hooks`. Verify version,
   requirements, checksums, documentation URL, and the downloaded package's source
   and README bytes against the verified candidate.
2. Inspect versioned HexDocs pages, links, and notebook download. Confirm the
   package page renders the release README.
3. Run the notebook normally, with no source override, against the exact published
   version. Run the production consumer against the released archive as well.
4. Create the GitHub release from the verified tag with notes from its CHANGELOG
   section. Confirm tag, release, `main`, and Hex all identify the intended version.
5. Complete operator records, record observed checks and any unobserved integration
   boundaries, and remove only this run's disposable services and unused scratch.

The release is complete when those observations are recorded. A successful publish
command alone is not a verification receipt.
