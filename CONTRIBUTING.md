# Contributing

## Development environment

AshHooks supports Elixir `~> 1.20`, Erlang/OTP 28 and 29, and Ash `>= 3.38.1 and < 4.0.0-0`.
The repository pins Elixir 1.20.5 and Erlang/OTP 29.1.2 in `.tool-versions` for development.
Use macOS or Linux; Windows contributors should use WSL2 and clone inside its Linux filesystem.

Work from a Git checkout of the [repository](https://github.com/baselabs/ash_hooks).
The commands below use its development configuration, tests, and release scripts.

Set Ash's required string-length counting mode before compiling host resources. The test
application uses:

<!-- tested: contributing-string-config -->
```elixir
config :ash, default_string_length_count: :codepoints
```

Install dependencies and run the default suite (SQLite):

<!-- not-run: These commands install dependencies and run the contributor project checks. -->
```sh
mix deps.get
mix compile --warnings-as-errors
mix test
```

Ordinary tests use the repository's SQLite test application. PostgreSQL tests require a
real PostgreSQL 16 or later service and run only when `ASH_HOOKS_POSTGRES=1` is set. Configure the
connection with `ASH_HOOKS_TEST_PG_HOST`, `ASH_HOOKS_TEST_PG_PORT`,
`ASH_HOOKS_TEST_PG_USER`, `ASH_HOOKS_TEST_PG_PASSWORD`, and
`ASH_HOOKS_TEST_PG_DATABASE`.

The PostgreSQL delivery qualification also uses a real WebHook Tester receiver.
For first-time setup, start the receiver from the repository root:

<!-- not-run: This starts a persistent receiver service and requires an available local port. -->
```sh
docker compose -f ops/local/webhook-tester.compose.yaml up -d
curl -fsS http://127.0.0.1:52871/api/version
```

For a different free loopback port, set `LOCAL_WEBHOOK_TESTER_PORT` on the Compose
command and set `ASH_HOOKS_REAL_RECEIVER_PORT` to the same port for tests. Reuse
an existing receiver when available; do not restart another user's service or
remove capture data. See the [receiver guide](https://github.com/baselabs/ash_hooks/blob/main/ops/local/README.md). CI provides
the receiver alongside PostgreSQL. Its PostgreSQL job runs the public platform
engine checked in `.github/postgres.ref` and the compatibility majors declared
once in `.github/postgres-lanes`, using digest-pinned upstream images. The reader
in `scripts/postgres-lanes.py` supplies both the matrix and compatibility images
and refuses a lane for the engine's major. Each lane starts a disposable server
on IPv4 loopback and removes it after the job.

## Testing changes

- Preserve exact bytes across inbound verification and outbound signing. Tests should
  assert the bytes observed by the receiver, not only the request assembled in memory.
- Exercise both the default resource shape and affected supported variants, including
  tenancy, renamed or composite ledger keys, UUIDv7 endpoint/subscription keys, and
  optional Oban/Plug absence where relevant.

Coverage is 100% of the surface declared in `mix.exs`; whole-module exclusions are
outside that denominator. Do not add an exclusion to hide reachable runtime behavior.
Add a meaningful test for reachable behavior or remove an unreachable branch.

Run focused checks while developing. Before a push, run:

<!-- not-run: This runs the contributor project qualification and changes generated build artifacts. -->
```sh
mix precommit
```

CI fetches project dependencies from committed locks with `--check-locked`.
A change to the package requirements or to a supported floor
also refreshes the two floor locks. The production consumer's lock is the graph
CI compiles and audits at the floor. The floor lock is the development graph at
the floor, which the full-suite qualification below runs on:

<!-- not-run: This resolves the floor graphs' dependencies. -->
```sh
(cd test/consumer && MIX_ENV=prod mix deps.get)
elixir scripts/check-ash-floor.exs --update-lock
```

To move a package in the floor graph to its newest admitted release, for example
after an advisory, name it; the script unlocks it and resolves again:

<!-- not-run: This resolves the floor graph's dependencies. -->
```sh
elixir scripts/check-ash-floor.exs --update-lock db_connection
```

CI does not run on pull requests. A maintainer runs the full workflow on the
exact commit before it reaches `main`, and reports any failure on the pull
request.

CI only restores build caches. The one writer is
`.github/workflows/cache-warmer.yml`, which runs hourly on `main` and builds each
key CI restores from the committed lock: every test lane (the default lane with
its Dialyzer PLTs), the floor and dev. A commit that changes `mix.lock` qualifies
on a cold build until the warmer next runs.

To qualify the full suite on exact Ash 3.38.1 and Spark 2.7.6, configure PostgreSQL
and the local receiver as described above, then run:

<!-- not-run: This requires configured PostgreSQL and local receiver services and sends a request to a public HTTPS receiver. -->
```sh
ASH_HOOKS_POSTGRES=1 ASH_HOOKS_HTTPBUN=1 elixir scripts/check-ash-floor.exs
```

This full-suite check includes a real HTTPS request using the endpoint configured in
`test/ash_hooks/tenant_worker_postgres_test.exs` and consumes a persisted Oban.Basic
job in a fresh BEAM process. It runs on the committed `test/floor/mix.lock`, fetched
with `--check-locked`, and keeps the main lock, dependencies, and build files
unchanged by using `_build/ash-floor` for the minimum supported graph and removing it
on exit. Ash requires Spark 2.7.6 or later; older Spark versions cannot resolve
with the supported Ash floor. Opt-in
public HTTPS checks run in CI qualification and are excluded from ordinary tests.

## Documentation and confidentiality checks

The required documentation run is enabled with `ASH_HOOKS_DOCS_REQUIRED=1`.
It needs PostgreSQL, the real receiver, and `ASH_HOOKS_HTTPBUN=1` for the public
HTTPS examples. Without those flags, optional service tests and the final
execution-completeness check are excluded. Static dispositions and consumer
formatting remain part of the ordinary tests. Each block uses its dependencies'
formatter exports. A lane without a block's dependency reports why its format
check is skipped; full lanes must check every block.

`scripts/check-confidentiality.sh` scans tracked files, the built archive, and
generated HTML and Markdown docs using `PUBLIC_DOCS_DENYLIST` from the caller's
environment. The live policy test is excluded when that variable is absent;
the scanner itself refuses an empty policy. Synthetic scanner tests always run.
`scripts/check-document-dashes.py` checks the archive and generated HTML and
Markdown surfaces. Generated HTML is checked without rewriting it. The checker
reads the build's project name and version through Mix without compiling or
starting the application. Only ExDoc's final page-title separator before that
identity and its index redirect separator before `Documentation` are exempt.
Authored title and body text remain subject to the dash check. CI runs the
confidentiality scan, required-document qualification, and publication dash
checks, and requires them in `qualified`.
Local optional-service runs remain focused unless their flags are enabled.

## Code and documentation

- Keep consumer-owned boundaries explicit: applications own migrations, Ash policies,
  secret storage, business effects, queue scheduling, and retention scheduling.
- Security changes must preserve finite resource bounds and reject unverified
  input before business processing. Review the public contracts for signature
  verification, destination checks, secret resolution, transport, tenancy,
  and delivery ownership before changing those paths.
- Record user-visible changes in `CHANGELOG.md` and set the version and publication date at release.
  Update `mix.exs`, the comparison link, and install constraints. Document required adopter
  changes to code, schema, or operations in `UPGRADING.md`.

## Bugs and security reports

Use the repository's
[issue templates](https://github.com/baselabs/ash_hooks/issues/new/choose) for bugs and
feature requests. Report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md).

## Releases

CI builds the Hex package and docs archives with the shared Hex action. Keep
`.github/hex-packages.json` in sync with the shipped files and requirements.
The version author lands the qualified commit on `main` and hands off its SHA
and CI run to the release maintainer. The release maintainer dispatches the
keyless upload with `release_commit` and the selected `qualification_run`.
If Hex stages the release, the owner approves it on hex.pm and the release
maintainer dispatches again with the original run. Tagging follows read-back.
See the [publishing runbook](https://github.com/baselabs/ash_hooks/blob/main/docs/PUBLISHING.md).

The [architecture decisions](https://github.com/baselabs/ash_hooks/tree/main/docs/adr)
record the package contracts and their consequences for hosts.

The development runtime and CI runtime lanes are pinned only in `.tool-versions`
files, read by `scripts/toolchain.sh`.
