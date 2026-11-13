# Agents

Instructions for coding agents working in this repository. People should start with
[CONTRIBUTING.md](CONTRIBUTING.md), which this file follows.

## Build and test

Commands run from the repository root on the toolchain pinned in `.tool-versions`. PostgreSQL
tests need a real PostgreSQL service and `ASH_HOOKS_POSTGRES=1`; see CONTRIBUTING.md for the
connection variables and the real receiver the delivery tests use.

- **Build.** `mix compile --warnings-as-errors`.
- **Covering tests.** `mix test <paths>` for the changed files and their direct dependents. A change
  to storage, tenancy or the worker also runs those paths with `ASH_HOOKS_POSTGRES=1`.
- **Before a push.** `mix precommit`, in the test environment: format check, compile with warnings as
  errors (test support included), `credo --strict`, the generated DSL documentation check, the
  documentation build with warnings as errors, and the candidate Hex archive check; with the changed
  files' covering tests. Not Dialyzer, not the full suite.
- **Exceptions.** A change to the minimum supported Ash graph runs `scripts/check-ash-floor.exs` as
  CONTRIBUTING.md describes. A change to the Livebook runs it headless against the candidate archive
  (`scripts/run-livebook.sh`).
- **Development tooling.** None beyond the dependencies in `mix.exs`.
- **Landing.** CI's full suite runs on the landing branch before `main` moves.
- **CI.** One `ci.yml`: the Elixir and Erlang/OTP matrix with the no-optional leg, the minimum
  supported graph, PostgreSQL with coverage, Dialyzer, the package and documentation checks, the
  headless Livebook, and `security` (the offline advisory scan of the lock and of the lock a
  consumer resolves at the declared floors). `all-checks-pass` is the verdict.
