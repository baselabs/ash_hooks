# 0007: Synchronous inbound processing and ledger keys

Status: Accepted August 21, 2026; amended November 15, 2026.

## Decision

The inbound pipeline is synchronous by default: verify, ingest, claim, handle,
and mark run in the caller's request. Applications that acknowledge with 202
own their queue, acknowledgment policy, and orchestration over public ingest,
claim, mark, renew, and reap operations. The outbound driver supplies no inbound
async runtime; the optional HTTP adapter calls synchronous ingress.

Ledger ownership uses complete metadata-derived primary keys. With custom
generated keys, ingest pre-reads for created/duplicate classification; concurrent
first arrivals can both report `:created`. The unique row and fenced claim still
deduplicate processing. Classification does not guarantee effect-once handling.
See [Ingress](../../lib/ash_hooks/ingress.ex) and
[delivery ownership](0012-durable-delivery-ownership-and-recovery.md).

Claim, mark and renew put the status, token and expiry predicates in the update's WHERE
clause, so the database checks the fence in the same atomic write. Injected actions
remain write primitives. This avoids depending on action-level filter behavior on atomic
updates and database-specific error expressions.

For a sole writable `:id` primary key, submit a fresh caller-generated ID and compare it
with the surviving upsert row. This classifies creation without a backend-specific
inserted-versus-conflict return flag. Custom primary keys use the documented pre-read
classification and its concurrent-race limit.
