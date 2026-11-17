# Agents

Use the pinned toolchain in `.tool-versions`. [CONTRIBUTING.md](CONTRIBUTING.md) describes
SQLite, PostgreSQL connection variables, and real receiver setup.

## Build and test

- **Build.** `mix compile --warnings-as-errors`.
- **Covering tests.** `mix test <paths>` for changed files and their direct dependents. Changes
  to storage, tenancy, or the worker also run those paths with `ASH_HOOKS_POSTGRES=1`.
- **Before a push.** Run `MIX_ENV=test mix precommit` and the covering tests.
- **Exceptions.** A change to the minimum supported Ash graph runs the full suite through
  `scripts/check-ash-floor.exs` as CONTRIBUTING.md describes. A Livebook change runs against
  the candidate archive with `scripts/run-livebook.sh`.

The development default and every CI lane are pinned only in `.tool-versions` files, read by `scripts/toolchain.sh`.
