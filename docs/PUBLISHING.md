# Publishing ash_hooks

A release is the Hex package, its versioned HexDocs, the executable Livebook,
and an annotated tag and GitHub Release that name the published commit.

Releases run only through `.github/workflows/publish.yml`, dispatched from
`main` with the full lowercase `release_commit` SHA. Landings continue while
publication runs. Nobody publishes from a workstation. The Hex key exists only
as the `HEX_API_KEY` secret of the repository's `publish` environment, and only
the upload step receives it. The build and read-back jobs never receive the key.

## Who does what

1. **The maintainer who prepares the release cuts the version.** They choose
   the version under the
   [support policy](adr/0010-semver-and-support-policy.md) and make one commit
   that updates:
   - `@version` in `mix.exs`;
   - the dated `CHANGELOG.md` heading and its comparison link;
   - the `UPGRADING.md` anchor and heading for the release;
   - the install constraints in `README.md`, the get-started tutorial and the
     documentation examples test;
   - each notebook's validated version, exact package pin and links;
   - the supported range in `SECURITY.md`, the version in `usage-rules.md`
     and the tenancy adoption checklist.

   `main` moves only after the CI run on a landing's head passes `qualified`,
   the check that requires every job: the package, Livebook, documentation,
   confidentiality and dash checks among them. The release commit is the
   version commit when it was a landing's head, otherwise the first later
   qualified commit with the same package. They give the release maintainer
   the repository, the full SHA as `release_commit`, the version, what goes out,
   and a link to its green `qualified` run.
2. **The release maintainer asks the owner and dispatches.** After the owner
   approves, the release maintainer dispatches the workflow from `main` with
   the handed-off SHA as `release_commit`. All jobs admit only the owner's
   accounts, and publication requires dispatch from `main`.
   The `publish` environment, which holds the key, admits only `main`.
3. **The workflow publishes and reads the release back.** See
   [What the workflow checks](#what-the-workflow-checks).
4. **The release maintainer tags and records the release.** With infra's
   `bin/release-tag`, they first compare the package in `release-assets` with
   the archive Hex serves. The helper pushes the annotated tag `v<version>`
   on the published commit named by the served docs' `release.json` and the
   run summary, then creates the GitHub Release with both archives and
   `SHA256SUMS`. It writes the release notes from the version's
   section of the compared package's changelog. They then confirm that
   the tag, the Release and Hex name the same version. Earlier release
   notes may link forward, but they are not backfilled with changes they omitted.

## What the workflow checks

`Verify the qualified release source` gates every later job and refuses any
dispatch ref other than the default branch. Only `Upload inspected assets` uses
the protected `publish` environment. No job restores or writes a build cache.

Verification requires exactly 40 lowercase hexadecimal characters in
`release_commit` and checks out that SHA. It checks these in order:

1. The commit must be reachable from the current head of `main` and have a
   successful GitHub Actions check named `qualified` on that exact SHA.
2. The selected commit's `mix.exs` must be UTF-8 without a BOM and declare
   exactly one `@version` as a string-literal semantic version. Verification
   parses the source without evaluating it. The tag `v<version>` must not
   exist on origin. An indeterminate lookup refuses.

`Build release assets` checks out the verified SHA and checks these before
installing the runtime:

1. The package name `ash_hooks` must exist on hex.pm. A first publication of a
   new name is the owner's decision, made by the owner, and this workflow
   refuses it. An indeterminate lookup refuses.
2. A missing version may continue. An existing, unretired version may continue
   so a second dispatch can finish an earlier upload. A retired version or an
   indeterminate response refuses.
3. `CHANGELOG.md` must hold exactly one nonempty section for the version.

The build installs the selected commit's Elixir and OTP defaults from
`.tool-versions` and the Hex client shared with qualification. It fetches with
`mix deps.get --check-locked`, checks generated formatter and DSL references
against the commit, and runs `mix spark.check`.
`scripts/check-package.sh` builds and inspects the package archive, with
`ASH_HOOKS_NO_OPTIONAL` unset so Oban and Plug remain optional requirements. It
checks the version, optional requirements, required documents, relative links,
release-tag links to shipped files, every file's bytes against the checkout,
and the publication dash rule.

The build also runs `mix docs --warnings-as-errors` with optional dependencies,
then writes `release.json` at the docs root:
`{"package": "ash_hooks", "version": ..., "commit": ...}`, with the selected
`release_commit`. Docs render files the package does not carry, such as `mix.lock`,
which pins ExDoc, so equal package bytes do not say which commit built served
docs; `release.json` does. The build checks the rendered documentation's dash
rule and builds the docs archive with Hex's own archive builder. Inspection
requires a `release.json` naming this package, version and commit, safe relative paths,
regular files only, no semantic-version top-level name, top-level `index.html`
and `readme.html`, and exactly the generated tree's file set and bytes. The
file set is the one `mix hex.publish` uses: every regular file except names
that start with a dot, such as ExDoc's build manifests.
Qualification builds and inspects the same docs archive. The build refuses a
checkout that differs from the commit.

After checking the packaged changelog, the build checks Hex anonymously and
plans each upload. It marks a served package for skipping only when its
SHA-256 matches the inspected package, and marks served docs for skipping.
It hands the inspected archives, `plan.json`, and `SHA256SUMS` to the upload
job as `inspected-archives`. The checksum manifest covers both archives and
the plan. Consumer files leave the workflow only as `release-assets`, which
`Read back` assembles from the bytes hex.pm serves. Consumers verify the files
attached to the GitHub Release for `v<version>`.

`Upload inspected assets` starts on a separate runner that has run no project
code. Its sparse checkout of `release_commit` contains only the shared runtime
action, the shared toolchain reader it calls, and the upload script.
It installs the build's exact runtime and Hex client, downloads
`inspected-archives`, confirms the manifest's SHA-256 against the build job's
output, and verifies each file before reading the plan.

Only the upload step receives `HEX_API_KEY`, through its environment. Its script
runs outside a Mix project and refuses a loaded project before reading the key.
It rechecks the current Hex state even when the plan skips both archives.
An upload-only retry skips an already served package with the inspected
checksum and skips docs already served for that package. A planned skip
refuses if Hex no longer serves that archive. A different checksum, retired
version, or uncertain state also refuses. The script uploads the package first
with replacement disabled. Before posting docs directly to a served release,
it rechecks that Hex serves an unretired release with the inspected package's
outer SHA-256 and `has_docs: false`. Hex 2.7.0 sends an unconditional POST,
and the Hex server writes the docs without a create-only precondition.
Another publisher can still change the release or write docs between the
check and the POST. The POST can replace docs written during that window.
[Hex client request](https://github.com/hexpm/hex/blob/92cb6a1b10c9b008ccb6fa229f5d9916840dc09d/lib/hex/api/release_docs.ex#L24-L53) ·
[Hex server write](https://github.com/hexpm/hexpm/blob/5e638200c2b1fbdb3412e18c7b433071ade3305e/lib/hexpm/repository/assets.ex#L25-L35)

Docs bytes can differ across builds of one commit because ExDoc 0.40.4 can
order its search data differently. HTTP errors report a status without
printing response bodies, headers, or credentials.

If Hex holds the package for approval, the script posts the inspected docs
with the same credential and requires Hex to confirm that both archives are
staged under the inspected package's outer SHA-256. One approval publishes
both archives. If the package is already served and Hex holds only the docs,
one approval publishes the docs. The script reports the held upload's kind,
approval URL, expiration, and archive SHA-256. Dispatch once more with the
same `release_commit` to read back both archives.
[Hex attaches docs to the staged release](https://github.com/hexpm/hexpm/blob/5e638200c2b1fbdb3412e18c7b433071ade3305e/lib/hexpm/repository/staged_releases.ex#L190-L233) ·
[Hex publishes the attached docs on approval](https://github.com/hexpm/hexpm/blob/5e638200c2b1fbdb3412e18c7b433071ade3305e/lib/hexpm/repository/staged_releases.ex#L501-L528)

`Read back` checks out `release_commit` and requires all of the following:

- The package archive Hex serves has the inspected package SHA-256.
- Hex serves a docs archive for the version: safe relative paths, regular files
  only, top-level `index.html` and `readme.html`, and a `release.json` naming
  `ash_hooks`, the version, and either `release_commit` or an ancestor of it.
  That commit is the published commit. Served docs are refused if
  `release.json` is missing, has duplicate keys, or names a commit outside
  the selected commit's history. Their bytes are not compared with a build.
- The Hex registry signature verifies against the pinned Hex.pm public key.
  The version's release record must be unretired and contain the inspected
  outer checksum.
- HexDocs serves the version.
- The get-started Livebook runs against the published package from hex.pm with
  a real receiver.

After the registry check and before it runs any project or dependency code,
`Read back` assembles `release-assets` with both archives hex.pm serves and their
`SHA256SUMS` in `sha256sum` format. Code that runs
later, such as the Livebook's dependencies, cannot alter what it recorded. The
run summary records `release_commit`, the published commit and `SHA256SUMS`.
Only after the whole read-back succeeds, Livebook included, does the release
maintainer push the tag and create the GitHub Release from `release-assets`.

## When a run fails

- **A failure in the build or before the upload step.** This run uploaded
  nothing. A required code fix lands on `main` through qualification before
  another dispatch. An earlier run may already have uploaded either archive.
- **An upload held for approval.** The owner approves it once on hex.pm. The
  release maintainer dispatches once more from `main` with the same
  `release_commit` to compare the served package and read back both archives
  before pushing any tag.
- **A partial upload or other upload failure.** An upload-only retry rechecks
  what Hex serves while the `inspected-archives` artifact is available. It
  expires after one day. After expiration, dispatch again from `main` with
  the same `release_commit`. Other package bytes or a retired version refuse.
- **A read-back failure caused by propagation delay.** The release maintainer
  re-runs only the failed `Read back` job. The successful build and upload jobs
  do not run again. A new dispatch with the same `release_commit` can also finish the
  release while no tag exists and the served package matches.
- **A persistent read-back failure, retired version, or differing served package.**
  The release maintainer reports it to the owner, who decides whether to retire
  the version. A required code fix ships as the next version through the same
  path. No tag or GitHub Release records an unverified publication.
