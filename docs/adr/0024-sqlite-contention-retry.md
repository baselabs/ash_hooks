# 0024 - SQLite contention retry

## Context

SQLite allows one writer at a time. When more than one connection writes to the
ledger or the delivery table, a write can fail with "database busy" or "database
is locked" even though nothing is wrong. Ingress and the dispatcher both write
under fences (ADR 0003, ADR 0012), so repeating a refused fenced write is safe.
Either the write takes effect once, or the fence refuses it. Some journal modes
also block readers while a writer holds the database. The idempotent reads around
these transitions must tolerate the same contention.

## Decision

One package module owns the contention rule. Ingress and the dispatcher both call
it.

- **Classification.** A result counts as contention only when every error in it
  is an Exqlite error whose text is "database busy" or "database is locked". No
  other data layer's errors can match, so PostgreSQL hosts see no change in
  behavior.
- **Retry.** The same operation runs again after 100 ms plus up to 50 ms of random
  jitter. Retries continue while less than 2 seconds have passed since the first
  attempt, measured on the monotonic clock.
- **Outcomes that end immediately.** Every other result returns at once: success,
  `:lease_held`, `:stale_token` and any other error.
- **What it wraps.** The rule wraps fenced or idempotent writes: ingest, claim,
  finalization, renewal, prune and delivery state transitions. It also wraps the
  idempotent reads around them: ingress dedup lookup, the reaper scan and receipt
  reload; dispatcher delivery lookup and reload, subscription reads, subsequent
  subscription or recovery pages, endpoint resolution and the recovery scan. It
  wraps no handler call and no outbound request.

The deadline is checked between attempts, so it does not limit how long one
database call takes. The busy timeout of the host's repository bounds that.

## Consequences

Under write contention, a request on SQLite waits up to about two seconds longer
before it succeeds, or returns the underlying error. It never produces a duplicate
or a lost update, because every write it repeats is fenced or idempotent and
repeated reads have no side effects. The classifier depends on the error text that Exqlite produces through Ash. A change in that text turns
contention back into an ordinary error, and the tests that run SQLite with
contending writers catch it.
