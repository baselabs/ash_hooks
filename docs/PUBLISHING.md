# Publishing ash_hooks

A release is the Hex package, its versioned HexDocs, the executable Livebook,
and an annotated tag and GitHub Release that name the published commit.

Releases run only through `.github/workflows/publish.yml`, dispatched from
`main`. Nobody publishes from a workstation. The Hex key exists only as the
`HEX_API_KEY` secret of the repository's `publish` environment, and only the
step that runs `mix hex.publish` receives it.

## Who does what

1. **The project session cuts the version.** It chooses the version under the
   [support policy](adr/0010-semver-and-support-policy.md) and makes one
   commit that updates:
   - `@version` in `mix.exs`;
   - the dated `CHANGELOG.md` heading and its comparison link;
   - the `UPGRADING.md` anchor and heading for the release;
   - the install constraints in `README.md`, the get-started tutorial and the
     documentation examples test;
   - each notebook's validated version, exact package pin and links;
   - the supported range in `SECURITY.md`, the version in `usage-rules.md`
     and the tenancy adoption checklist.

   The commit lands on `main` through kimosabe-land. The CI run on that exact
   commit passes every job, including `all-checks-pass`, which runs the
   package, Livebook, documentation, confidentiality and dash checks. The
   session then hands the release to infra-1 with the repository, the full
   commit SHA, the version and anything the release needs first.
2. **infra-1 asks the owner and dispatches.** After the owner approves,
   infra-1 dispatches the workflow from `main`. The job runs only for the
   owner's accounts, and the `publish` environment admits only `main`.
3. **The workflow publishes and reads the release back.** See
   [What the workflow checks](#what-the-workflow-checks).
4. **infra-1 tags and records the release.** infra-1 pushes the annotated tag
   `v<version>` on the commit the run published, and creates the GitHub
   Release from that tag. The Release carries the version's `CHANGELOG.md`
   notes, plus the commit and archive SHA-256 from the run summary. infra-1
   then confirms that the tag, the Release, `main` and Hex name the same
   version. Earlier release notes may link forward, but they are not
   backfilled with changes they omitted.

## What the workflow checks

The `Publish` job refuses to publish when any of these holds:

- the run is on any ref other than the default branch;
- the installed Elixir or OTP differs from the defaults in `.tool-versions`,
  the same file CI reads;
- `v<version>` is already on Hex or already exists as a tag, or either lookup
  gives no definite answer;
- `mix deps.get --check-locked` would change `mix.lock`;
- the formatter export or the generated DSL references differ from
  `mix spark.generate`, or `mix spark.check` fails;
- `scripts/check-package.sh` rejects the archive. It checks:
  - the version;
  - that the `oban` and `plug` requirements are optional;
  - that every required document ships;
  - that every relative link resolves inside the archive;
  - that repository links to shipped files name `v<version>`;
  - that every file matches the checkout byte for byte;
  - the publication dash rule.
- `mix docs --warnings-as-errors` warns, or the rendered HexDocs break the dash
  rule;
- the checkout differs from the commit being published.

The job then publishes with `ASH_HOOKS_NO_OPTIONAL` unset, so the optional
Oban and Plug requirements are published as optional. A full publish updates
the package and its documentation together.

The `Read back` job has no access to the key. It requires all of the following:

- the archive Hex serves has the SHA-256 of the archive the `Publish` job
  inspected;
- the signed Hex registry lists the version with that checksum;
- HexDocs serves the version;
- the get-started Livebook runs against the published package from hex.pm,
  with a real receiver.

The run summary records the commit and the archive SHA-256.

## When a run fails

- **A failure before `Publish to hex.pm`.** Nothing reached Hex. The fix lands
  on `main` like any other change, and infra-1 dispatches again from the new
  head.
- **A failure in `Read back` that a retry can clear,** such as a registry or
  HexDocs delay. infra-1 re-runs the failed job only. The `Publish` job has
  already succeeded and does not run again.
- **A failure in `Read back` that persists.** The version is out, and Hex
  archives are immutable. infra-1 reports it to the owner, who decides whether
  to retire the version. The fix ships as the next patch version through this
  same path.
