# 0012: Durable delivery ownership and recovery

Status: Accepted October 6, 2026; amended November 15, 2026.

## Context

Shared ledgers need durable declaration and route ownership, fenced attempts,
and recoverable queue admission and endpoint disablement across independent stores.

## Decision

Persist a versioned declaration source and queue route on each outbound row.
Keep endpoint/event uniqueness, including tenant partitioning. A mismatched
source is a conflict. Named callbacks provide stable routes; anonymous callbacks
may provide a host-owned stable key. Deferred routes bind once; unkeyed anonymous
routes require an explicit recovery mapping. The worker validates resource,
source, route, complete row key, and tenant before executing.

Use separate UUID tokens and expiring leases for send admission and queue
recovery. Claims are atomic queries over the complete primary key, tenant,
ownership, state, due time, cap, and lease. Every result must match the live send
token. An empty matched result is stale ownership and emits no result telemetry.
An owned, monitored process bounds secret resolution, destination resolution,
transport, and result handling. Oban's timeout exceeds this driver budget and its
finalization allowance. Application UTC time governs leases; synchronized
application-node clocks are a deployment prerequisite.

A live 410 response first stores `disable_pending` and a snapshot of endpoint
configuration references. Recovery conditionally disables only that captured
configuration and finalizes once it is disabled, authoritatively gone, or replaced.
Read/write errors preserve the obligation. Reentry completes it without sending
again. The snapshot contains references and mapped state, never secret material.

Recover stale pending rows, enqueue failures, due retries, expired sends, and
pending-disable obligations through the matching declaration and durable route.
Keep attempts and retry times. Oban uniqueness uses the complete runnable-job
identity; admission succeeds only with a persisted matching runnable job.
Discarded/completed jobs do not prevent a fresh recovery trigger.

Ledger keys are metadata-derived complete maps. Endpoint/subscription reference
columns remain UUID-compatible and therefore require single UUID-compatible keys
where declarations join resources. Typed status mappings are cast and constrained
before execution, reject overlapping states, and cannot map a primary-key attribute.

- Adding declaration ownership to dedup identity would create separate rows with
  the same receiver-facing webhook ID at one endpoint.

## Consequences

Hosts migrate ownership columns and states, drain incompatible jobs, backfill
ownership and routes, and deploy matching workers together. The ordered
procedure is in [UPGRADING](../../UPGRADING.md).

The ledger maintains one authoritative live attempt and fences its results.
Network delivery remains at-least-once: a lease cannot retract a request already
accepted by a receiver. Hosts schedule recovery and make handlers/receivers idempotent.

## Inbound identity

Configured JWS-body providers use
[Scheme.payload_identity/1](../../lib/ash_hooks/provider/scheme.ex) to hash
full canonical JSON with sorted object keys and no omitted fields. Payload
changes change identity; alternate signatures and object-key order do not.
A declaration event extractor takes precedence, then the provider identity
callback, then the signed-body digest. Callback errors fail closed.
Applications implement any custom normalization explicitly and audit identity
adoption in a quiesced transaction, preserving payloads and digests and
terminalizing superseded siblings. Declaration names never infer a provider. See
[generic providers](0017-generic-providers-and-signature-primitives.md).
Tenant transactions and renewed resend allowance follow
[transaction ownership](0015-tenant-transactions-and-spawned-work.md) and
[resend](0020-resend-replay-and-endpoint-health.md) while preserving identity
and live result ownership.
