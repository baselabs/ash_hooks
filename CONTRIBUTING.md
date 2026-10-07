# Contributing

Thank you for improving AshHooks. Keep pull requests focused, explain the behavior that
changes, and include the evidence needed to review that behavior.

## Development environment

AshHooks supports Elixir `~> 1.20`, Erlang/OTP 28 and 29, and Ash `>= 3.34.3 and < 4.0`.
The repository pins Elixir 1.20.4 and Erlang/OTP 28.5 in `.tool-versions` for development.
Use macOS or Linux; Windows contributors should use WSL2.

Work from a Git checkout of the [repository](https://github.com/baselabs/ash_hooks).
The commands below use its development configuration, tests, and release scripts.

Set Ash's required string-length counting mode before compiling host resources. The test
application uses:

```elixir
config :ash, default_string_length_count: :codepoints
```

Install dependencies and run the fast suite:

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
Set `ASH_HOOKS_REAL_RECEIVER_PORT` to its existing loopback port (default 52871).
CI provides the receiver alongside PostgreSQL. Check the receiver's `/api/version`
endpoint before the test run.

## Testing changes

- For new behavior or a safety check, write the regression first and run it to observe the
  intended failure before changing the implementation. Keep both the failing and passing
  command output in the pull request evidence.
- Do not add mocks, stubs, fake services, canned socket peers, self-signed conformance
  fixtures, or hard-coded samples standing in for a real call. Exercise the real database,
  queue, receiving service, protocol endpoint, or vendor-published vector. If the required
  substrate is unavailable, stop and describe what is needed rather than replacing it.
- Existing test doubles may support isolated unit checks, but a passing double establishes
  only the local call contract. Boundary and interoperability claims require a real peer.
- Provider changes need the vendor's current public signing documentation, official test
  vectors when published, malformed-input cases, and a real integration check when the
  provider offers a test surface.
- Preserve exact bytes across inbound verification and outbound signing. Tests should
  assert the bytes observed by the receiver, not only the request assembled in memory.
- Exercise both the default resource shape and affected supported variants, including
  tenancy, renamed or composite ledger keys, UUIDv7 endpoint/subscription keys, and
  optional Oban/Plug absence where relevant.

Run focused checks while developing. Before opening a pull request, run the repository
gate:

```sh
mix format --check-formatted
mix hex.audit
mix compile --warnings-as-errors
mix credo --strict
mix test
ASH_HOOKS_POSTGRES=1 mix test --cover
mix dialyzer
./scripts/check-currency.sh
```

The coverage gate runs the complete suite with PostgreSQL and the real receiver
available. It requires 100% in the coverage surface declared in `mix.exs`.
Mix's exclusions apply to whole modules: generated DSL entities, named test fixtures,
three Ash types, and the installer. The types and installer have separate tests;
their runtime lines do not contribute to the reported percentage. Do not add an
exemption to hide reachable code; add a meaningful test or remove the unreachable branch.

To qualify a persisted tenant worker on the exact Ash minimum, configure PostgreSQL
as above and run:

```sh
ASH_HOOKS_POSTGRES=1 ASH_HOOKS_HTTPBUN=1 elixir scripts/check-ash-floor.exs
```

This opt-in check uses Httpbun's public HTTPS `/status/103` endpoint and a fresh BEAM
process consuming a real Oban.Basic job. It keeps the checkout's main lock, dependency,
and build files unchanged, using `_build/ash-floor` for the minimum graph. Public
Httpbun checks are excluded from ordinary tests and CI; use them deliberately and
respect the service's usage policy.

When a change affects generated DSL documentation or the package surface, also run:

```sh
mix spark.cheat_sheets --extensions AshHooks,AshHooks.Endpoint,AshHooks.Subscription,AshHooks.InboundDelivery,AshHooks.OutboundDelivery --check
mix docs
./scripts/check-package.sh
```

CI additionally checks the minimum supported Elixir/Ash consumer graph, Erlang/OTP 28 and
29, an installation with Oban and Plug absent, real PostgreSQL behavior, the candidate
Hex archive, and the headless Livebook against that archive. A pull request is ready to
merge only when the aggregate `all-checks-pass` job succeeds.

## Code and documentation

- Public behavior includes the DSL, public functions, injected attributes and actions,
  telemetry payloads, error classes, and worker options. Update tests and user-facing docs
  together when one of these changes.
- Keep consumer-owned boundaries explicit: applications own migrations, Ash policies,
  secret storage, business effects, queue scheduling, and retention scheduling.
- Security changes must preserve finite resource bounds and fail-closed behavior. Read the
  applicable decision record under
  [docs/adr](https://github.com/baselabs/ash_hooks/tree/main/docs/adr) before changing
  verification, SSRF handling, secret resolution, transport, tenancy, or delivery fences.
- Add a decision record for a new long-lived architectural contract. Do not use one for a
  routine defect correction.
- Use US English in code, documentation, tests, commit messages, and pull requests.
- Add user-visible changes to `CHANGELOG.md` under `## Unreleased`, and add migration
  steps to `UPGRADING.md` when an adopter must change code, schema, or operations.

## Bugs and security reports

Use the repository's
[issue templates](https://github.com/baselabs/ash_hooks/issues/new/choose) for bugs and
feature requests. Report vulnerabilities privately as described in
[SECURITY.md](https://github.com/baselabs/ash_hooks/blob/main/SECURITY.md).

## Releases

Releases are maintainer-only. The authoritative procedure is the
[publishing runbook](https://github.com/baselabs/ash_hooks/blob/main/docs/PUBLISHING.md).
