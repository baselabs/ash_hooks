# 0022 - Oban engine row security

## Context

ADR-0015 requires tenant-bound queue insertion on the ledger repository. That
repository cannot also run Oban's engine under a tenant-only job policy:
fetching, staging, rescue, pruning, and acknowledgments run without a tenant
binding. Database leadership uses `oban_peers`, which has no tenant attribute.
Direct worker execution does not exercise those engine operations.

## Decision

Hosts using forced row security on PostgreSQL supervise separate insertion and engine instances sharing a database,
prefix, and PostgreSQL notifier. The worker's `oban:` option names the
insertion instance, which uses the ledger's runtime repository and disables
queues, plugins, peer leadership, and staging. The insert joins the tenant
phase after the delivery persists, preserving ADR-0015's transaction contract.

The runtime role has SELECT and INSERT on `oban_jobs` with tenant-keyed
policies and sequence USAGE. The generated worker's unique insert performs an
advisory lock and SELECT before INSERT with RETURNING; it does not request
conflict replacement. No runtime UPDATE, DELETE, or peer-table grant is needed.

The engine instance uses its own repository and login role. Both `oban_jobs`
and `oban_peers` enable and force row security, with policies covering all rows
for the engine role. Neither login is a superuser, bypasses row security, owns
the tables, or inherits ownership privileges. The engine role receives queue
metadata privileges without access to tenant ledgers. The worker's `perform/1`
opens its package phases on the runtime repository using the job's tenant.

The PostgreSQL notifier publishes inserts on the prefix's `oban_insert`
channel at commit; different instance names do not separate that channel.
The engine's stager also discovers due jobs and signals available queues.
Host-scheduled recovery, retention, health, key-lifecycle, and registry work
still runs per tenant as ADR-0015 requires.

The [guide](../../documentation/tutorials/row-security.md) owns the executable
SQL and supervision examples. Real PostgreSQL tests execute those blocks with
deployment identifiers substituted, through restricted login connections.
They exercise live queue completion, HTTP snoozes, execution errors and
exhaustion, peer leadership, notifications, and runtime isolation. Accepted
records remain unchanged; this record clarifies the two repository roles.

## Alternatives

- A tenant-only engine policy hides jobs because engine processes have no
  tenant binding, leaving deliveries pending indefinitely.
- Granting the runtime role unrestricted job access lets application queries
  cross tenant boundaries. A dedicated engine role confines that authority
  to queue metadata.
- Making the engine a table owner, superuser, or row-security bypass role
  conceals missing policies and broadens privileges beyond queue operations.
- Calling `perform/1` directly proves package tenant binding but cannot prove
  engine fetches, state transitions, maintenance, or database leadership.

## Consequences

Hosts provision two role credentials and repository pools and own both Oban
supervision entries. Existing job arguments and package APIs stay unchanged.
Engine SQL runs unbound with explicit policies; package ledger work remains
tenant-bound. Queue privileges and documentation are checked together.
