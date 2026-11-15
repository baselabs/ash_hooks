# 0020 — Resend, replay, and endpoint health

- **Status:** Accepted November 15, 2026
- **Deciders:** maintainer

## Context

Operators need to repeat completed delivery work, send retained events to an
endpoint, and stop sustained failures without silently changing receiver
identity or erasing attempt history. Warning state must survive restarts and
overlapping maintenance sweeps. These operations were introduced in 2.2.0 and
refined through 3.2.0.

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
for a chosen endpoint: it creates missing delivery rows with declaration and
enqueue-route ownership, rearms terminal rows with the same tenant and
requester, and skips nonterminal rows. Both forms preserve event IDs. Dry runs
count their selected batches without writing; limits and rate settings bound
work. Repeated event-log calls can select skipped rows again and do not return
a pagination cursor.

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

## Alternatives

- Resetting lifetime attempts on resend would reuse audit identities and erase
  accounting. A baseline renews allowance while preserving history.
- Issuing a new event identity for every resend would defeat receiver
  deduplication. Keeping the identity makes the repeat explicit and safe for
  receivers honoring that contract.
- Disabling on the first qualifying sweep was the earlier implementation,
  corrected in 2.2.1 because it could skip warning. A transient warning alone
  cannot survive restart; the later interval check also prevents overlapping
  sweeps from collapsing the notification window.
- Automatic re-enablement would resume traffic without host review of the
  failure. The shipped contract requires an explicit action.
- Treating subscription pause as cancellation would alter accepted work.
  Preventing new rows preserves the existing delivery lifecycle.

## Consequences

Hosts authorize requesters and endpoint state changes, migrate enabled features,
and schedule per-tenant health sweeps. Retention affects both replay availability
and the evidence behind health statistics. Resend may immediately use a large
lifetime-based backoff, even with renewed allowance. Receivers must deduplicate
the preserved webhook ID across retries and operator-triggered repeats.
