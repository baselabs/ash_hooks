# ADR-0004 — Optional Oban via host-injected worker boundary

- **Status:** Accepted (2026-08-20) — uniqueness assertion VERIFIED 2026-08-21
  against local `deps/oban` 2.23.1 (see ADR-0007's substrate record:
  confirmed valid; defaults `period: 60`/`states: :successful` must be
  overridden; keys-absent args silently degrade uniqueness; implemented on
  PG/MySQL/SQLite engines alike)
- **Deciders:** operator (ratified), scout best-of-N + adversarial review

## Context

Outbound delivery needs a durable job runtime; inbound-only consumers must not pull queue
infrastructure. A package-level `use Oban.Worker` module cannot compile when the optional
dep is absent — and current Oban uniqueness config requires `fields: [:args]` with
`keys: [...]` (nested arg keys are not DB fields).

## Decision

`{:oban, "~> 2.20", optional: true}`. The delivery runtime is a behaviour
(`AshHooks.Delivery`); the Oban adapter is a **host-injected `use AshHooks.Worker` macro**
that expands `use Oban.Worker` inside the consuming app — the Oban beam only compiles where
Oban exists; queue configuration stays host-owned. Selecting the Oban adapter without Oban
fails deterministically before any delivery work is accepted. The package compiles
Oban-free, proven by a compile-matrix gate and an inbound-only fixture app asserting Oban
never loads. No Oban APIs beyond 2.20 (2.21+ requires PostgreSQL 14).

## Consequences

- Inbound-only installs stay queue-free; both first-party adopters (already on Oban) opt in
  by defining one worker module.
- Consumers must define the worker module themselves (one line) — documented in the
  installer.
