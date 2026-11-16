# Publishing ash_hooks

A release includes the Hex package, versioned API docs, executable Livebook,
and matching GitHub source and release notes.

## Prepare the release

1. Choose the version under the [support policy](adr/0010-semver-and-support-policy.md).
   Update `mix.exs`, install constraints, supported floors, upgrade guidance,
   and each notebook's validated version and exact package pin. Date the
   CHANGELOG release heading and add its comparison link.
2. Regenerate the formatter export and DSL references:

   ```sh
   mix spark.generate
   ```

3. Build and inspect the candidate archive and documentation:

   ```sh
   ./scripts/check-package.sh
   mix docs --warnings-as-errors
   ```

   `usage-rules.md` and the tutorial, DSL, and Livebook trees must ship in the
   archive and render on HexDocs. Every repository-relative document named by
   shipped documentation must also ship. Inspect rendered README, guides, API
   links, and generated DSL pages; resolve every warning and broken reference.
4. Run each notebook against the candidate archive:

   ```sh
   ./scripts/run-livebook.sh documentation/livebooks/get-started.livemd --archive _build/release/ash_hooks-<version>.tar
   ```

   The runner serves the candidate and dependency tarballs from a temporary
   signed registry. The notebook's unmodified `Mix.install` verifies checksums,
   and the runner checks the installed candidate byte for byte.
   The existing real receiver must answer on `LOCAL_WEBHOOK_TESTER_PORT`
   (default 52871). Reuse it rather than starting a second receiver.
5. Dry-run publication with optional dependency metadata enabled:

   ```sh
   env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish --dry-run
   ```

   Inspect the version, package name, file list, and optional `oban`/`plug` flags.
   Confirm that the Hex package belongs to the maintainer account.

## Publish and verify

Supply `HEX_API_KEY` from the maintainer's secret store, scoped to this command.
Never keep the key in a project file, print it, log it, or copy its value:

```sh
env -u ASH_HOOKS_NO_OPTIONAL mix hex.publish --yes
```

A full publish updates package and documentation together. The Hex package page
renders the README and metadata from its immutable versioned archive. Changing
those bytes requires a version bump and full publish. A docs-only publish can
refresh HexDocs without a version bump but cannot update the package archive.

After publication:

1. Read the release through Hex's API and `mix hex.info ash_hooks`. Verify the
   version, requirements, checksums, documentation URL, source, and README bytes
   against the candidate.
2. Inspect versioned HexDocs pages, links, and notebook download. Confirm that
   the package page renders the release README.
3. Run each notebook against its exact published version:
   `./scripts/run-livebook.sh documentation/livebooks/get-started.livemd`.
   Without `--archive`, the runner resolves packages from hex.pm. Run the
   production consumer against the released archive as well.
4. Create the GitHub release from `v<version>` with its CHANGELOG notes. Confirm
   that the tag, release, `main`, and Hex identify the intended version. Prior
   release notes may link forward; do not backfill them with omitted changes.
