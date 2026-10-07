# ADR-0003 — Dedup is a fenced unique-ingest ledger (not ash_onetime)

- **Status:** Accepted (2026-08-20)
- **Deciders:** maintainer, corrected against implementation evidence; independent design review

## Context

Providers deliver at-least-once; receivers must dedup. Candidate primitive 1: the sibling
`ash_onetime` extension — but it hard-depends `ash_postgres` + `postgrex`, which would force
Postgres on every consumer and defeat data-layer agnosticism. A unique delivery-audit
table records arrival but does not by itself recover unfinished processing. A crash
between ingest and finalization must leave a row that redelivery can claim again.

## Decision

**2.0 amendment:** [ADR-0012](0012-durable-delivery-ownership-and-recovery.md)
adds provider-defined identity precedence, explicit legacy adoption, and complete
ledger primary-key handling. The content-digest fallback below applies only when
neither the declaration nor its provider defines an identity.

Dedup is `AshHooks.InboundDelivery`: decoded payload and signed-body digest persisted
before handling, DB-unique
identity `{provider, external_event_id}` extended by consumer-declared scope slots (provider
ids are not globally unique across accounts), deterministic content-hash identity for
providers without ids (never a fresh UUID), and a **fenced claim/lease state machine**
(`received → claimed → processed | failed`; claim returns a monotonic fencing token;
mark/renew conditional on token; a reaper re-drives expired leases). Data-layer-agnostic
(unique-upsert via supported Ash data-layer mechanisms; ash_sqlite supports them natively —
verified). `ash_onetime` remains an optional dep for consumers who want action-level
idempotency elsewhere.

## Consequences

- A crash leaves unfinished processing recoverable. A crash after a handler's effect but
  before finalization can repeat that effect; handlers must be idempotent.
- Uniqueness identity must include declared scope where configured (verifier enforces).
- Byte-identical distinct deliveries from no-id providers dedupe to one event — documented
  at-least-once semantics (no identity exists to distinguish them).
