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

## Toolchain and dependency currency

The toolchain is self-enforcing and lockstep-pinned to Elixir 1.20.4 /
Erlang/OTP 28: the exact Elixir pin in `mix.exs`, `.tool-versions`, and
CI's elixir/otp versions move together in ONE commit — divergence between
the three is a defect. A foreign Elixir refuses at deps loadpaths
(`Mix.ElixirVersionError`); a foreign OTP runtime refuses in
`config/config.exs` before anything compiles.

Dependency currency is checked mechanically, not remembered:

```
./scripts/check-currency.sh    # nonzero on resolver-updatable drift
mix hex.audit                  # re-run after EVERY dependency move
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
