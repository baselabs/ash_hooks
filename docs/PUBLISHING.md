# Publishing ash_hooks

A release records the package and docs served by Hex, their checksums, and the
GitHub tag and release for the source commit. Publication uses GitHub workload
identity through the [shared Hex action](https://github.com/baselabs/.github/tree/654fcd0ef63daf8e3f79dfeb4ca900adffd0d4e2/.github/actions/hex-publish).

## Version author

1. Choose the version under the [support policy](adr/0010-semver-and-support-policy.md).
   Update `@version` in `mix.exs`, the dated changelog heading and comparison
   link, and the release heading and anchor in `UPGRADING.md`. Keep any sections
   above the version's changelog heading empty.
2. Update the install constraints in the README, get-started tutorial and
   documentation examples test. Update each notebook's version, package pin and
   release links, plus the supported version in the security policy, usage
   rules and tenancy adoption checklist. Use `baselabs_ash_hooks-v<version>`
   for new release links.
3. Land the commit on `main` after the CI run on `kci/<full SHA>` passes
   `qualified`. Hand off the repository, full SHA as `release_commit`, version,
   release contents, and green CI run URL to the release maintainer.

The package job installs the locked BEAM runtime and the shared action's pinned
Hex client. The action builds the archives, verifies the package files and
requirements against `.github/hex-packages.json`, compares packaged files with
the commit, and compiles a consumer using the project's lock. It builds HexDocs
in HTML and Markdown, includes a root `release.json` with the package, version
and commit, and retains both archives with their manifest in
`hex-hexpm-ash_hooks` for seven days. Qualification checks the archives' dash
rules, the packaged documentation links, and the Livebook against the candidate
archive with a real receiver.

## Release maintainer

1. Obtain owner approval to dispatch `publish.yml` from `main`. Pass the full
   40-character lowercase `release_commit` SHA and the handoff CI run ID as
   `qualification_run`. If the run ID is omitted, upload selects the earliest
   successful CI run for that exact SHA that still retains the package
   artifact, so a repeat dispatch reuses the same archives.
2. Verify the upload result. The shared action checks the commit's ancestry,
   green `qualified` job, artifact provenance, archive bytes, stamped changelog,
   tag and registry state. For public Hex it confirms the package exists
   anonymously. The organization API-read key is used only in the protected
   upload job to check for a private release of the same application and
   version. The upload job runs Hex outside the checkout and uses a short-lived,
   package-scoped workload token for any uploads.
3. If Hex holds the release for approval, upload stops and names what needs
   approval (package and docs, or docs alone), the hex.pm staged-release page
   and Hex's approval checksum. The owner checks that checksum on the page and
   approves there. Dispatch again with the same `release_commit` and the **original**
   `qualification_run` to reuse the exact archives.
4. Wait for read-back and the published Livebook job. Read-back uses the run ID
   and qualified manifest checksum from upload, verifies the signed Hex registry
   and exact served archive bytes, and records `release-assets` with both
   archives and `SHA256SUMS`. The published Livebook job checks the versioned
   HexDocs page and runs the notebook against hex.pm with a real receiver.
5. Use the published commit from read-back to record the annotated
   `baselabs_ash_hooks-v<version>` tag and GitHub release. Attach the verified
   archives and `SHA256SUMS` and use the packaged changelog for release notes.
   Confirm the tag, GitHub release and Hex agree. Existing `v<version>` tags
   remain the release records for versions published under those tags.

If upload is interrupted or the served archives need time to propagate, reuse
the original qualification. A fresh artifact after expiration can proceed only
if it matches any archive Hex already serves. Report a retired version or an
archive mismatch to the owner before recording a release.
