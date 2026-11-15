# 0019 — Delivery audit and observation

- **Status:** Accepted November 15, 2026
- **Deciders:** maintainer

## Context

Delivery state, attempt history, emitted-event history, and inbound rejection
counts answer different operational questions. Optional observation must not
change a send result or prevent fanout, and an observed counter must not claim
to measure requests that never reached durable storage. Version 2.2.0 introduces
the optional history resources and query surfaces.

## Decision

The outbound delivery row remains the authoritative delivery contract.
[AshHooks.OutboundAttempt](../../lib/ash_hooks/outbound_attempt.ex) records
one idempotent audit row per complete delivery key and lifetime attempt number,
after the fenced result transition succeeds. It records outcome, classified
reason, HTTP status, request latency, signing-key reference, and test marker.
No signing material is stored. Attempted requests include transport and
certificate failures and 410 disable recovery; paths that make no request have
no request latency or signing reference. Older stored disable obligations may
lack those fields.

[AshHooks.OutboundEvent](../../lib/ash_hooks/outbound_event.ex) records each
dispatched event idempotently, independently of whether any endpoint receives
it. The row holds event identity, type, declared version, time, and exact emitted
payload bytes. Event-log write failures do not stop fanout; attempt-history
write failures do not fail the send. Failures emit
`[:ash_hooks, :event, :record_failed]` or
`[:ash_hooks, :attempt, :record_failed]` with classified reasons. Neither
optional write can replace the delivery ledger's ownership or result fence.

Response capture is off by default. Per-endpoint capture requires explicit
columns and a row opt-in, byte bounds, package redaction, and a closed response
header allowlist. Direct diagnostic capture also passes the redaction floor;
a failing host redactor leaves a sanitized summary. The package does not
persist inbound request headers.

Delivery, attempt, inbound receipt, and event list APIs use tenant preflight
and newest-first `(time, id)` keyset pagination. Malformed cursors fail as
`:invalid_cursor`; a full last page still carries a cursor. Timestamps and an
id attribute are required by these query contracts. Event logs have independent
retention. Pruning deliveries with joined attempt history rolls back the batch
if history deletion fails.

With `ingress_tracking :on`,
[Ingress.counts/2](../../lib/ash_hooks/ingress.ex) counts stored rejection rows
and persisted duplicate counters. Rejections contain a placeholder and a
raw-body digest identity, not the rejected body. A failed rejection write
does not change the refusal. Paused sources, custody unavailability, and unknown
callback failures create no rejection rows and do not increase the verification
failure count. Counts therefore describe stored observations, not all requests.

`Delivery.test_send/2` creates a fresh signed synthetic event directly for one
live endpoint, bypassing subscription lookup entirely. It uses the selected
type and signing mode, defaults to standard signing and one attempt, and drives
the normal runtime and optional history. Delivery test tracking is opt-in;
history carries the test marker. ADR-0020 owns resend, replay, and health policy.

## Alternatives

No alternative was recorded at the time in the available release notes.
Making optional audit writes mandatory could turn an observation outage into
duplicate network delivery or blocked fanout. Telemetry alone cannot provide
durable per-attempt queries or replayable event bytes. Counting refusal callbacks
as stored failures would overstate durable history after rejected writes or
paused traffic. Routing test sends through subscriptions could suppress the
diagnostic request and would not test the chosen endpoint directly.

## Consequences

Hosts opt into and migrate audit resources, govern payload and captured-response
access, and schedule retention. Missing audit rows are observable but possible;
health and replay can use only the history actually retained. Receiver-facing
delivery remains at-least-once, and test sends reach real configured transports.
