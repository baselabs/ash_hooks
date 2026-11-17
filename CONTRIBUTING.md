# Contributing

## Development environment

AshHooks supports Elixir `~> 1.20`, Erlang/OTP 28 and 29, and Ash `>= 3.37.2 and < 4.0.0-0`.
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

```sh
docker compose -f ops/local/webhook-tester.compose.yaml up -d
curl -fsS http://127.0.0.1:52871/api/version
```

For a different free loopback port, set `LOCAL_WEBHOOK_TESTER_PORT` on the Compose
command and set `ASH_HOOKS_REAL_RECEIVER_PORT` to the same port for tests. Reuse
an existing receiver when available; do not restart another user's service or
remove capture data. See the [receiver guide](https://github.com/baselabs/ash_hooks/blob/main/ops/local/README.md). CI provides
the receiver alongside PostgreSQL.

## Testing changes

- Preserve exact bytes across inbound verification and outbound signing. Tests should
  assert the bytes observed by the receiver, not only the request assembled in memory.
- Exercise both the default resource shape and affected supported variants, including
  tenancy, renamed or composite ledger keys, UUIDv7 endpoint/subscription keys, and
  optional Oban/Plug absence where relevant.

Run focused checks while developing. Before a push, run:

```sh
mix precommit
```

To qualify a persisted tenant worker on exact Ash 3.37.2 and Spark 2.7.6, configure PostgreSQL
as above and run:

```sh
ASH_HOOKS_POSTGRES=1 ASH_HOOKS_HTTPBUN=1 elixir scripts/check-ash-floor.exs
```

This opt-in check sends a real HTTPS request using the endpoint configured in
`test/ash_hooks/tenant_worker_postgres_test.exs` and consumes a persisted Oban.Basic
job in a fresh BEAM process. It keeps the main lock, dependencies, and build files
unchanged by using `_build/ash-floor` for the minimum supported graph and removing it
on exit. Ash requires Spark 2.7.6 or later; older Spark versions cannot resolve
with the supported Ash floor. Opt-in
public HTTPS checks are excluded from ordinary tests and CI.

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

Releases are maintainer-only. The authoritative procedure is the
[publishing runbook](https://github.com/baselabs/ash_hooks/blob/main/docs/PUBLISHING.md).

The [architecture decisions](https://github.com/baselabs/ash_hooks/tree/main/docs/adr)
record the package contracts and their consequences for hosts.
