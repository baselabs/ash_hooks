# Publishing ash_hooks

A release is the Hex package, its versioned HexDocs, the executable Livebook,
and an annotated tag and GitHub Release that name the published commit.

Releases run only through `.github/workflows/publish.yml`, dispatched from
`main`. Nobody publishes from a workstation. The Hex key exists only as the
`HEX_API_KEY` secret of the repository's `publish` environment, and only the
upload step receives it. The build and read-back jobs never receive the key.

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

   `main` moves to the commit only after the CI run on that exact commit
   passes `qualified`, the check that requires every job: the package,
   Livebook, documentation, confidentiality and dash checks among them. They
   then hand the release to the release maintainer with the full commit SHA,
   the version and anything the release needs first.
2. **The release maintainer asks the owner and dispatches.** After the owner
   approves, the release maintainer dispatches the workflow from `main`. All
   three jobs run only for the owner's accounts, and the `publish` environment
   admits only `main`.
3. **The workflow publishes and reads the release back.** See
   [What the workflow checks](#what-the-workflow-checks).
4. **The release maintainer tags and records the release.** They push the
   annotated tag `v<version>` on the commit the run published. They compare the
   package archive in `release-assets` with the archive hex.pm serves, then
   create the GitHub Release for that tag from the artifact. The Release carries
   both archives, `SHA256SUMS`, and `RELEASE-NOTES.md`, including the version's
   changelog section, commit, and both SHA-256 values. They then confirm that
   the tag, the Release, `main` and Hex name the same version. Earlier release
   notes may link forward, but they are not backfilled with changes they omitted.

## What the workflow checks

Every job first refuses any ref other than the default branch. All three jobs
admit only the owner's accounts. `Build release assets` and `Upload inspected
assets` use the protected `publish` environment; `Read back` has no environment
and no access to the key. No job restores or writes a build cache.

`Build release assets` installs the exact Elixir and OTP defaults from
`.tool-versions` and the exact Hex client shared with qualification. Before
building, it checks these in order:

1. The tag `v<version>` must not exist on origin. An indeterminate lookup refuses.
2. The package name `ash_hooks` must exist on hex.pm. A first publication of a
   new name is the owner's decision, made by the owner, and this workflow
   refuses it. An indeterminate lookup refuses.
3. A missing version may continue. An existing, unretired version may continue
   so a second dispatch can finish an earlier upload. A retired version or an
   indeterminate response refuses.

The build fetches with `mix deps.get --check-locked`, checks generated formatter
and DSL references against the commit, and runs `mix spark.check`.
`scripts/check-package.sh` builds and inspects the package archive, with
`ASH_HOOKS_NO_OPTIONAL` unset so Oban and Plug remain optional requirements. It
checks the version, optional requirements, required documents, relative links,
release-tag links to shipped files, every file's bytes against the checkout,
and the publication dash rule.

The build also runs `mix docs --warnings-as-errors` with optional dependencies,
checks the rendered documentation's dash rule, and builds the docs archive
with Hex's own archive builder. Inspection requires safe relative paths,
regular files only, no semantic-version top-level name, top-level `index.html`
and `readme.html`, and exactly the generated tree's file set and bytes. The
file set is the one `mix hex.publish` uses: every regular file except names
that start with a dot, such as ExDoc's build manifests.
Qualification builds and inspects the same docs archive. The build refuses a
checkout that differs from the commit.

One artifact, named `release-assets`, holds the inspected package and docs
archives, `SHA256SUMS` in `sha256sum` format, and `RELEASE-NOTES.md`. Release
notes require a nonempty changelog section for the version and record the
commit and both SHA-256 values. Consumer verification uses the files attached
to the GitHub Release for `v<version>`; workflow artifacts expire.

`Upload inspected assets` starts on a separate runner that has run no project
code. Its sparse checkout contains only the shared runtime action and the
registry-state and upload scripts. It installs the build's exact runtime and
Hex client, downloads `release-assets`, checks `SHA256SUMS`, and compares both
archive hashes with the build job's outputs. Nothing is rebuilt.

Before receiving a key, the upload job checks hex.pm anonymously:

- A missing package archive is uploaded. An already served archive is skipped
  only when its SHA-256 equals the inspected package archive. A different
  checksum or a retired version refuses.
- Missing docs are uploaded. Already served docs are skipped only when the
  served docs archive has the inspected docs SHA-256. Different bytes refuse.

Only the upload step receives `HEX_API_KEY`, through its environment. Its script
runs outside a Mix project and refuses a loaded project before reading the key.
It uploads the inspected package first with replacement disabled, then the
inspected docs, only for the parts the anonymous decision marked missing. It
never replaces a package or published docs. HTTP errors refuse without printing
response bodies, headers, or credentials.

If Hex holds either upload for approval, the script reports its kind, approval
URL, expiration, and archive SHA-256. It attempts both requested uploads before
exiting with failure to mark the hold. When both are staged as one release,
their staged release checksums must match.

`Read back` requires all of the following:

- The package archive Hex serves has the inspected package SHA-256.
- The docs archive Hex serves has the inspected docs SHA-256.
- The signed Hex registry lists the version with the inspected package checksum.
- HexDocs serves the version.
- The get-started Livebook runs against the published package from hex.pm with
  a real receiver.

The run summary records the commit, version, and both archive SHA-256 values.
Only after read-back succeeds does the release maintainer push the tag and
create the GitHub Release from `release-assets`.

## When a run fails

- **A failure in the build or before the upload step.** This run uploaded
  nothing. A required code fix lands on `main` through qualification before
  another dispatch. An earlier run may already have uploaded either archive.
- **An upload held for approval.** The owner approves it on hex.pm. The release
  maintainer then dispatches again on the same commit, before pushing any tag.
  The new run builds and compares both archives, uploads only what is missing,
  and reads both back. A hold is never reported as a completed publication.
- **A partial upload or other upload failure.** A second dispatch on the same
  commit finishes it when already served bytes match. Other bytes or a retired
  version refuse. The workflow never replaces an archive to make a retry pass.
- **A read-back failure caused by propagation delay.** The release maintainer
  re-runs only the failed `Read back` job. The successful build and upload jobs
  do not run again. A new dispatch on the same commit can also finish the
  release while no tag exists and both served archives match.
- **A persistent read-back failure, retired version, or differing served bytes.**
  The release maintainer reports it to the owner, who decides whether to retire
  the version. A required code fix ships as the next version through the same
  path. No tag or GitHub Release records an unverified publication.
