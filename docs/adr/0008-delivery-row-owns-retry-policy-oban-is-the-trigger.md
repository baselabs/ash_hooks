# The delivery row owns retry policy

## Decision

The `OutboundDelivery` row owns retry policy; Oban supplies a durable trigger.
Terminal rows return `:ok`. A retryable row before `next_attempt_at` snoozes
without consuming its row-owned allowance. Atomic claims, attempt tokens, and
send leases fence admission and results as defined in
[delivery ownership](0012-durable-delivery-ownership-and-recovery.md).
The driver owns its deadline. Worker timeouts and attempt limits must leave
room for that budget and finalization. Network delivery is at-least-once;
receivers deduplicate the stable `webhook-id`, derived from `event_uuid`.

Default classification is 2xx success; 408, 429, and 5xx retry; 410 durable endpoint
disablement and dead-letter; other 4xx dead-letter; and redirects refused.
Transport and secret-resolution failures retry with backoff. Unsafe destinations,
disabled or missing endpoints, and certificate pin failures are terminal;
DNS failures retry. Backoff is capped exponential delay with jitter and a
one-second floor. Retryable HTTP responses honor integer or HTTP-date
`Retry-After`, clamped to `retry_after_cap_seconds` rather than the backoff cap;
missing or malformed headers use backoff.

`retryable_statuses` replaces the ordinary HTTP failure set with statuses or
ranges. Nil selects the defaults; an empty list retries no ordinary HTTP failure.
Success, redirects, and 410 behavior stay fixed. Invalid sets fail before claim.
See [host policies](0021-host-trust-boundaries-and-subscription-selection.md).

With `resend_tracking :on`, the send-series ceiling counts
`attempts - resend_baseline`. Resend preserves the row, receiver identity, and
monotonic lifetime attempts while advancing the baseline to renew allowance.
Exponential backoff uses lifetime attempts. See
[resend and replay](0020-resend-replay-and-endpoint-health.md).

## Consequences

- The ledger exposes retry state independently of the queue.
- The driver runs without Oban; the host defines its queue worker.
- A send lease cannot retract a request a receiver already accepted.
