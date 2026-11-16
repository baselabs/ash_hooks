# Fenced unique-ingest ledger

## Decision

`AshHooks.InboundDelivery` persists the decoded payload and signed-body digest
before handling. Its unique identity combines provider, external event ID, and
consumer-declared scope. Identity precedence is declaration extractor, provider
callback, then deterministic signed-body digest; callback errors fail closed.
A fenced claim and lease state machine moves receipts through
`received -> claimed -> processed | failed`. Claim tokens fence mark and renew
operations, and a reaper recovers expired leases. The data layer must supply
unique upserts and atomic conditional updates.
Complete primary keys and identity adoption follow
[the ownership decision](0012-durable-delivery-ownership-and-recovery.md).

## Consequences

- Crashes leave unfinished work recoverable. Handlers must be idempotent because
  a crash after a business effect but before finalization can repeat the effect.
- Uniqueness includes every declared scope attribute.
- Byte-identical deliveries without a sender identity deduplicate to one event.
- `ash_onetime` is not a dependency. Applications may independently choose an
  action-idempotency extension outside this package's dependency contract.
