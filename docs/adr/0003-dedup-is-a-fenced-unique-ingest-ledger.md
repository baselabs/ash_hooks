# 0003: Fenced unique-ingest ledger

Status: Accepted August 20, 2026; amended November 15, 2026.

Amended: November 27, 2026.

## Decision

`AshHooks.InboundDelivery` persists the decoded payload and signed-body digest
before handling. Its unique identity combines the source declaration name
(stored in `provider`), external event ID, and consumer-declared scope within
the tenant. Identity precedence is declaration extractor, provider callback,
then the signed-body digest. An unrecognized extractor result uses the body
digest. An invalid provider identity fails ingress.
A fenced claim and lease state machine moves receipts through
`received -> claimed -> processed | failed_retryable | failed_permanent`.
Claim tokens fence mark and renew operations, and a reaper recovers expired
leases. The data layer must supply
unique upserts and atomic conditional updates.
Complete primary keys and identity adoption follow
[the ownership decision](0012-durable-delivery-ownership-and-recovery.md).

A uniqueness-only arrival audit cannot recover unfinished processing; an expired claim
must be reclaimable after a crash. A separate deduplication dependency whose runtime
graph requires PostgreSQL would impose a storage choice on adopters, so the ledger uses
the host resource's Ash data layer.

## Consequences

- Crashes leave unfinished work recoverable. Handlers must be idempotent because
  a crash after a business effect but before finalization can repeat the effect.
- Uniqueness includes every declared scope attribute.
- Byte-identical deliveries without a sender identity deduplicate to one event.
- `ash_onetime` is not a dependency. Applications may independently choose an
  action-idempotency extension outside this package's dependency contract.

## Durable replay identity for timestamp-free signatures

A protected route reserves a versioned SHA-256 digest of the exact signed
body in the existing `unique_ingest` fence for its immutable authenticated
enrollment. Every route for that enrollment uses the same ledger declaration,
tenant, and cast scope. The host provisions current and overlap keys unique
to that enrollment and topic. Rotation preserves the namespace.

The first receipt owns handler input and recovery. Terminal compaction
discards the payload and handler metadata while retaining the receipt's
identity and outcome. Protected duplicates use that receipt without decoding
the request payload. Failure to reserve an identity asks the sender to retry.
Byte-identical deliveries in an enrollment coalesce. A signature without
time provides no age signal for a previously unseen body.

Legacy identity precedence and prune behavior continue on routes that leave
replay protection at its default. See [ADR 0026](0026-retention-action-injection.md)
for cleanup and authority retirement.
