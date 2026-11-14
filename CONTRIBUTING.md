# Contributing

Thank you for improving AshHooks. Keep pull requests focused, explain the behavior that
changes, and include the evidence needed to review that behavior.

## Development environment

AshHooks supports Elixir `~> 1.20`, Erlang/OTP 28 and 29, and Ash `>= 3.37.2 and < 4.0.0-0`.
The repository pins Elixir 1.20.5 and Erlang/OTP 29.1.2 in `.tool-versions` for development.
Use macOS or Linux; Windows contributors should use WSL2.

Work from a Git checkout of the [repository](https://github.com/baselabs/ash_hooks).
The commands below use its development configuration, tests, and release scripts.

Set Ash's required string-length counting mode before compiling host resources. The test
application uses:

<!-- tested: contributing-string-config -->
```elixir
config :ash, default_string_length_count: :codepoints
```

Install dependencies and run the fast suite:

<!-- tested: contributing-setup; not-run: Maintainer checkout setup; installs dependencies and runs the full suite, which includes this gate. -->
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
  database, queue, or receiving service is unavailable, stop and describe what is needed rather than replacing it.
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

Run focused checks while developing. Before every push, run the whole-tree gates in one
command: the format check, compilation with warnings as errors (test support included),
Credo, the generated DSL documentation check, the documentation build, the Hex archive check, and the documentation's mounting examples:

<!-- tested: contributing-precommit; not-run: Maintainer command; recursively invokes this documentation gate. -->
```sh
mix precommit
```

Before opening a pull request, run the repository gate:

<!-- tested: contributing-release; not-run: Maintainer release qualification; invokes this gate and requires PostgreSQL, the real receiver, and package-service access. -->
```sh
mix precommit
mix hex.audit
mix test
ASH_HOOKS_POSTGRES=1 mix test --cover
MIX_ENV=test mix dialyzer
./scripts/check-currency.sh
```

The type gate uses the test environment to compile the PostgreSQL suite's worker
from `test/support/postgres_worker.ex`. This checks the consumer code injected by
`use AshHooks.Worker` as well as the library modules.

The coverage gate runs the complete suite with PostgreSQL and the real receiver
available. It requires 100% in the coverage surface declared in `mix.exs`.
Mix's exclusions apply to whole modules: generated DSL entities, named test fixtures,
three Ash types, and the installer. The types and installer have separate tests;
their runtime lines do not contribute to the reported percentage. Do not add an
exemption to hide reachable code; add a meaningful test or remove the unreachable branch.

To qualify a persisted tenant worker on the exact Ash minimum, configure PostgreSQL
as above and run:

<!-- tested: contributing-ash-floor; not-run: Maintainer opt-in qualification; requires a configured PostgreSQL database and a public HTTPS receiver. -->
```sh
ASH_HOOKS_POSTGRES=1 ASH_HOOKS_HTTPBUN=1 elixir scripts/check-ash-floor.exs
```

This opt-in check sends a real HTTPS request using the endpoint configured in
`test/ash_hooks/tenant_worker_postgres_test.exs` and consumes a persisted Oban.Basic
job in a fresh BEAM process. It keeps the main lock, dependencies, and build files
unchanged by using `_build/ash-floor` for the minimum supported graph. Opt-in
public HTTPS checks are excluded from ordinary tests and CI.

CI additionally checks the minimum supported Elixir/Ash consumer graph, Erlang/OTP 28 and
29, an installation with Oban and Plug absent, real PostgreSQL behavior, the Hex archive, and the headless Livebook against that archive. A pull request is ready to
merge only when the aggregate `all-checks-pass` job succeeds.

## Code and documentation

Every code block in the Hex package and HexDocs carries a hidden `tested`
comment immediately before the fence or indented block. A run mark uses
`<!-- tested: name -->`. A fragment uses
`<!-- tested: name; not-run: Requires the host application's resource. -->`;
the reason is mandatory. The same comments live inside module documentation
and Spark descriptions so ExDoc renders no gate metadata.

`test/ash_hooks/documentation_examples_test.exs` reads the blocks unchanged,
compiles Elixir in its application context, runs SQL against SQLite and
PostgreSQL, and runs safe shell commands. Maintainer commands that recurse
into the gate or need host configuration state why they cannot run there.
The Livebook runs headlessly against the built package and real receiver.
Missing, duplicate, orphaned, and unexecuted marks fail, as do placeholders in
runnable blocks. Every Elixir block, including fragments and Livebook cells,
must match `Code.format_string!/2` with a line length of 98 and the formatter
exports of ash_hooks and every documented dependency. `mix spark.generate`
regenerates the formatter export and marked DSL references; `mix spark.check`
refuses drift.

- Public behavior includes the DSL, public functions, injected attributes and actions,
  telemetry payloads, error classes, and worker options. Update tests and user-facing docs
  together when one of these changes.
- Keep consumer-owned boundaries explicit: applications own migrations, Ash policies,
  secret storage, business effects, queue scheduling, and retention scheduling.
- Security changes must preserve finite resource bounds and reject unverified
  input before business processing. Review the public contracts for signature
  verification, destination checks, secret resolution, transport, tenancy,
  and delivery ownership before changing those paths.
- Use US English in code, documentation, tests, commit messages, and pull requests.
- Add user-visible changes to `CHANGELOG.md` in the entry matching the version declared in `mix.exs`, and add migration
  steps to `UPGRADING.md` when an adopter must change code, schema, or operations.

## Bugs and security reports

Use the repository's
[issue templates](https://github.com/baselabs/ash_hooks/issues/new/choose) for bugs and
feature requests. Report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md).

## Releases

Releases are maintainer-only. The authoritative procedure is the
[publishing runbook](https://github.com/baselabs/ash_hooks/blob/v3.1.0/docs/PUBLISHING.md).
