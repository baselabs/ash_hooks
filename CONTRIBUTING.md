# Contributing

Small, focused PRs against `main` are the fastest path. Before opening one:

## Setup

```
mix deps.get
mix test
```

The full local gate (what CI runs):

```
mix format && mix compile --warnings-as-errors && mix credo --strict && mix test
ASH_HOOKS_NO_OPTIONAL=1 mix test   # the Oban/Plug-free leg
mix dialyzer
```

## What good changes look like

- **Red-first tests for behavior changes.** A test that never failed proves nothing —
  watch it fail for the intended reason, then make it pass. The suite has mutation-proven
  tripwires (`test/support/ast_tripwire.ex` enforces constant-time compares on signature
  material); keep that bar.
- **Security posture is ADR-governed.** Changes touching verification, SSRF, secret
  handling, or memory bounds should cite (or propose) the governing ADR in
  `docs/adr/`. New product-shaping decisions get a new ADR.
- **Docs ship with the capability** (moduledoc + README/tutorial where user-visible +
  CHANGELOG entry under `## Unreleased`).
- **Providers** are only added when the vendor's signing scheme is publicly documented
  and verified first-hand; the acceptance fixtures come from the vendor's own docs.
- **No secrets in fixtures** — synthesized bytes only.

## Reporting bugs / security

See `.github/ISSUE_TEMPLATE/` for bugs and feature requests; SECURITY.md for
vulnerability reports (never a public issue).

## Release mechanics

Maintainer-only; the runbook is `docs/PUBLISHING.md`.
