# ADR-0004 — Optional Oban via host-injected worker boundary

- **Status:** Accepted (2026-08-20) — uniqueness assertion VERIFIED 2026-08-21
  against local `deps/oban` 2.23.1 (see ADR-0007's substrate record:
  confirmed valid; defaults `period: 60`/`states: :successful` must be
  overridden; keys-absent args silently degrade uniqueness; implemented on
  PG/MySQL/SQLite engines alike)
- **Deciders:** maintainer, validated against independent design reviews

## Context

Outbound delivery needs a durable job runtime; inbound-only consumers must not pull queue
infrastructure. A package-level `use Oban.Worker` module cannot compile when the optional
dep is absent — and current Oban uniqueness config requires `fields: [:args]` with
`keys: [...]` (nested arg keys are not DB fields).

## Decision

`{:oban, "~> 2.20", optional: true}`. As built (trued up 2026-08-22): the delivery runtime
is the concrete row-driven driver `AshHooks.Delivery` (ADR-0008; the package's one
pluggable behaviour is `AshHooks.Http`, not the runtime); the Oban integration is a
**host-injected `use AshHooks.Worker` macro** that expands `use Oban.Worker` inside the
consuming app and delegates each job to `AshHooks.Delivery.run/2` — the Oban beam only
compiles where Oban exists; queue configuration stays host-owned. Selecting the Oban
adapter without Oban fails deterministically before any delivery work is accepted. The
package compiles and runs Oban-free, proven by the CI no-optional matrix leg
(`ASH_HOOKS_NO_OPTIONAL=1`) plus an in-suite assertion
(`test/ash_hooks/oban_free_test.exs` and the CI `:code.which` step) that Oban never loads.
Uniqueness semantics were verified against Oban 2.23.1 (ADR-0007) — the `~> 2.20` floor
constrains APIs, not the verified version. (The earlier "2.21+ requires PostgreSQL 14"
note applies only to Oban's Postgres engine; MySQL/SQLite engines are unaffected.)

## Consequences

- Inbound-only installs stay queue-free; both first-party adopters (already on Oban) opt in
  by defining one worker module.
- Consumers must define the worker module themselves (one line) — documented in the
  installer.
