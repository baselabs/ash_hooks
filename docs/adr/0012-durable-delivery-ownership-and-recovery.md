# ADR-0012 — Durable delivery ownership and recovery

- **Status:** Accepted, October 6, 2026; effective in the published 2.0.1 release.
- **Deciders:** Maintainer's corrective-release request; independent adversarial
  design review and independent judgment.

## Context

An outbound ledger may serve several declarations and workers. Endpoint/event
uniqueness prevents parallel rows for one receiver-facing identity, but does not
identify which declaration or queue route owns the surviving row. An attempt
counter records accounting, but is writable by consumer actions and cannot fence
late results. A completed queue job must not prevent recovery of an unfinished
ledger row. Disabling an endpoint after a 410 also needs a durable obligation:
the endpoint write and ledger write can use different stores.

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

HubSpot's default identity canonicalizes the full event batch, excluding only
outer `attemptNumber` fields. Provider identity errors fail closed. Existing digest
rows require a quiesced, audited adoption transaction; payloads and digests remain
stored, and superseded siblings become terminal. Explicit host event extractors
retain precedence.

## Alternatives

- Using `attempts` as a fence fails when a consumer resets that writable counter.
- Adding declaration ownership to dedup identity would create separate rows with
  the same receiver-facing webhook ID at one endpoint.
- Holding queue uniqueness across terminal jobs strands unfinished ledger rows.
- Terminalizing before the endpoint write leaves a crash gap; assuming one shared
  transaction excludes supported resources in different stores.
- A worker-only timeout leaves direct delivery and pre-HTTP work unbounded.
- Guessing declaration ownership from current subscriptions loses historical routing.

## Consequences

The required columns and states make this a 2.0 migration. Drain old jobs, backfill
ownership and routes, adopt affected HubSpot partitions, and deploy matching workers
together. The ordered procedure is in [UPGRADING](../../UPGRADING.md).

The ledger maintains one authoritative live attempt and fences its results.
Network delivery remains at-least-once: a lease cannot retract a request already
accepted by a receiver. Hosts schedule recovery and make handlers/receivers idempotent.

This decision supersedes ADR-0008's all-state queue uniqueness, counter-only send
admission, and worker-only timeout. It extends ADR-0003's default identity,
ADR-0007's row-key classification, and ADR-0011's recovery admission. ADR-0009's
transport uses one total deadline and stops reading at the body cap in 2.0.
