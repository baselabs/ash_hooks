# ADR-0003 — Dedup is a fenced unique-ingest ledger (not ash_onetime)

- **Status:** Accepted (2026-08-20)
- **Deciders:** scout (Stage A answer corrected by Stage B evidence), cross-family adversarial review

## Context

Providers deliver at-least-once; receivers must dedup. Candidate primitive 1: the sibling
`ash_onetime` extension — but it hard-depends `ash_postgres` + `postgrex`, which would force
Postgres on every consumer and defeat data-layer agnosticism. Candidate primitive 2 (what
the reference platform actually built): a delivery-audit resource with DB-unique ingest on
`{platform, external_event_id}` — but the as-built version has a verified silent-loss
window: a crash between ingest commit and mark-processed strands a `:received` row that
redelivery treats as a no-op.

## Decision

Dedup is `AshHooks.InboundDelivery`: raw payload persisted before handling, DB-unique
identity `{provider, external_event_id}` extended by consumer-declared scope slots (provider
ids are not globally unique across accounts), deterministic content-hash identity for
providers without ids (never a fresh UUID), and a **fenced claim/lease state machine**
(`received → claimed → processed | failed`; claim returns a monotonic fencing token;
mark/renew conditional on token; a reaper re-drives expired leases). Data-layer-agnostic
(unique-upsert via supported Ash data-layer mechanisms; ash_sqlite supports them natively —
verified). `ash_onetime` remains an optional dep for consumers who want action-level
idempotency elsewhere.

## Consequences

- Crash between any two steps re-drives instead of silently dropping or double-processing.
- Uniqueness identity must include declared scope where configured (verifier enforces).
- Byte-identical distinct deliveries from no-id providers dedupe to one event — documented
  at-least-once semantics (no identity exists to distinguish them).
