# 0020: Resend, replay, and endpoint health

Status: Accepted November 15, 2026.

Amended November 27, 2026.

## Context

Resend, replay, and sustained-failure disablement must preserve identity and history.
Warnings must survive restarts and overlapping maintenance sweeps.

## Decision

[Delivery.resend/2](../../lib/ash_hooks/delivery.ex) rearms only terminal rows
for live endpoints, with a required requester and opt-in `resend_tracking`
columns. It preserves the row key, event identity, payload, and monotonic
lifetime attempt count. It advances `resend_baseline` so the ceiling applies to
`attempts - resend_baseline`, renewing the allowance without colliding with
earlier attempt-history identities. Backoff still uses lifetime attempts and
its exponential cap. Resend is not a reset of the delivery's history.

Delivery replay applies resend to a filtered, bounded set. Event-log
[replay/3](../../lib/ash_hooks/outbound_event.ex) instead selects emitted events
for a chosen endpoint. A new delivery requires an enabled endpoint and the same
active subscription, event-type, and filter match as fanout. Its bytes follow
the same catalog resolution for the endpoint's payload pin. Missing deliveries
with no eligible subscription or endpoint count as skipped. Replay rearms
terminal rows with the same tenant and requester and skips nonterminal rows.
Both forms preserve event IDs. Event-log dry runs count eligible new deliveries
without writing. Limits and rate settings bound work. Repeated event-log calls
can select skipped rows again and do not return a pagination cursor.

`outbound_event.replay_context :on` injects a nullable column for bounded
dispatch metadata and payload provenance. It retains only keys listed in the
subscription resource's `filter_attributes`. If those keys omit part of the
original metadata, replay cannot run a variant builder. A row with no captured
metadata returns a per-row error for an active, type-matching filtering
subscription. A missing delivery for an unpinned endpoint with an unfiltered
subscription remains eligible on older rows.

[AshHooks.EndpointHealth](../../lib/ash_hooks/endpoint_health.ex) derives health
from retained attempt rows. It distinguishes first-attempt and eventual success,
reports delivery counts, and computes latency percentiles from requests with
measured durations. Sustained-failure auto-disable is opt-in. A qualifying sweep
first persists `disable_warned_at` and then emits the warning. Disablement
requires continued qualifying evidence and the full warning interval, default
60 seconds, measured from that stored marker. Early and overlapping sweeps
cannot shorten it. Recovery below the warning band clears the marker; failed
writes are not counted or reported as successful warnings or disables.

The existing 410 durable disable obligation remains governed by ADR-0012.
Neither health recovery nor successful later traffic automatically re-enables
an endpoint. Re-enabling is a host-authorized manual action.

`subscription.pausable :on` injects a nonnullable `paused` boolean defaulting
to false. The declaration defaults to `:off`, with no added column. Pausing
stops new delivery-row creation for that subscription; already-created
deliveries continue. Hosts pause and resume through ordinary resource updates.
This is distinct from endpoint disablement, which the runtime also checks.

## Consequences

Hosts authorize requesters and endpoint state changes, migrate enabled features,
and schedule per-tenant health sweeps. Retention affects both replay availability
and the evidence behind health statistics. Resend may immediately use a large
lifetime-based backoff, even with renewed allowance. Receivers must deduplicate
the preserved webhook ID across retries and operator-triggered repeats.
