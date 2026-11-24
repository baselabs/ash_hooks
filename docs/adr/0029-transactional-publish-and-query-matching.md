# 0029. Transactional publish through an outbox, and query-side subscription matching

Status: accepted

## Context

dispatch/4 reads subscriptions, resolves endpoints, writes delivery rows and enqueues inside the
caller's transaction, so every step holds the caller's locks until commit. Subscription
matching read every tenant subscription and matched in memory (ADR 0021).

## Decision

1. A new outbox resource role holds accepted publications, keyed by (tenant, event_uuid), with a
   required deduplication horizon. publish/4 and AshHooks.Changes.Publish issue exactly one
   statement inside the caller's transaction: an upsert with no updated fields, whose returned
   acceptance token decides accepted versus duplicate. Publish refuses before writing unless the
   outbox shares the caller's data layer, write repository and dynamic repository instance.
2. After commit, a notifier hints a host-declared trigger route. A fenced, leased fanout runs the
   dispatch pipeline outside any caller transaction. A host-scheduled per-tenant sweep is the
   correctness path. Every committed publication ends done, decided per endpoint, or failed,
   parked with a persisted cause and rearmable. Delivery stays at-least-once (ADR 0012).
3. Outbox metadata is restricted to a JSON term domain that round-trips exactly. The stored
   payload version, not the deployed one, decides pin resolution.
4. Every dispatch path applies type, pause, and metadata filters through the primary read.
   PostgreSQL and SQLite use SQL predicates. Unsupported shapes widen to true,
   keeping the Elixir predicate as the final guard. Malformed filter containers
   never match, correcting a case that matched in 3.2.0.
   The metadata-filter arm is the non-recursive key-set test (5C). It was chosen over a recursive
   walk because the walk triggered PostgreSQL JIT. The filter arm costs up to 3.4 times the p95 of
   type and pause matching alone; the probe measured this on PostgreSQL 16 to 18.

## Consequences

Hosts that opt in add the outbox resource, its migration and grants, a trigger route and a
per-tenant sweep schedule. Hosts that do not opt in see no change except the matching
correction. The event log is unchanged. A GIN index on event_types is recommended.
