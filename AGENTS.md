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

## CI/CD and releases

- An agent's work ends when the change is on `main`. `main` moves only after the CI run on that
  exact commit passes `qualified`.
- Agents never publish, tag a version, create a release, dispatch a workflow, push an image or
  handle a registry or CI key. The release maintainer dispatches from `main` with the full
  qualified commit SHA as `release_commit`. Releases follow [docs/PUBLISHING.md](docs/PUBLISHING.md).
- A change to `.github/`, a release script or anything that touches a secret is reviewed by the
  release maintainer before it lands.
- A secret reaches a step only through its environment: never on a command line, in a log or in
  a message.
