# ADR-0008 — The delivery row owns the retry policy; Oban is the trigger

- **Status:** Accepted (2026-08-21)
- **Deciders:** operator (ratified), codex adversarial design pass (21 findings adjudicated)

## Context

The delivery runtime (#7) needs retries, Retry-After handling, jittered
backoff, a dead-letter ceiling, and the same webhook-id on every attempt.
Oban has its own retry machinery (job attempts, a backoff callback, job
states) — running BOTH systems means two schedules that can disagree, and
the delivery ledger row is already the durable audit record of every
attempt.

## Decision

**ONE policy source: the `OutboundDelivery` row.** Oban is the durable
TRIGGER only. `perform/1` loads the row and drives its state machine:

- terminal rows (`:succeeded` / `:dead_letter`) → `:ok` — the trigger is
  idempotent, the effect-once guarantee lives in the row;
- a `:failed_retryable` row before `next_attempt_at` → `{:snooze, s}` —
  snooze EXTENDS the job's `max_attempts` (verified in local oban 2.23.1,
  the uniqueness engine source of that release), so waiting never exhausts the job and only the ROW's
  `attempts >= ceiling` decides `:dead_letter`;
- the attempt itself: WHERE-gated atomic `mark_sending` (status flip +
  `attempts + 1` in ONE statement — the portable-fence pattern) BEFORE the
  HTTP adapter fires; a crash mid-send leaves a re-drivable `:sending`
  row (at-least-once — SW receivers dedup by `webhook-id`, which is the
  row's `event_uuid`, constant across retries by construction).

The job's own `max_attempts` is advisory (snoozes inflate it); the job
`timeout/1` (default 30s) is the stalled-peer bound.

**Uniqueness** (the ADR-0007-verified mechanism): `fields: [:args],
keys: [:endpoint_id, :event_uuid], period: :infinity, states: :all` —
both defaults overridden (60s / `:successful` would re-admit a duplicate
trigger after success or window expiry); a conflict is
`{:ok, %Job{conflict?: true}}` mapped to `:ok` (dedup success).

**Classification table** (single source, in `AshHooks.Delivery`): 2xx →
succeeded; 408/429 → retryable honoring Retry-After (integer seconds or
HTTP-date, clamped `[1, retry_after_cap]`); 410 → endpoint durably
`:disable`d + dead-letter; other 4xx → dead-letter (client errors do not
self-heal); 3xx → dead-letter (`redirect_refused` — never followed);
5xx/transport/secret-resolution failure → retryable backoff; send-time
SSRF refusal / disabled-or-gone endpoint → dead-letter.

**Backoff**: `min(base·2^min(attempts,16), max_backoff)` plus
`uniform(delay)` jitter, re-clamped, floor 1 second.

## Alternatives rejected

- Oban-driven backoff: two policy sources diverge on Retry-After, and the
  audit row would stop being the record of the schedule.
- Row-driven rescheduling without Oban (a reaper): loses the durable
  trigger's crash-safety and queue backpressure that motivated optional
  Oban in ADR-0004.
- Freezing endpoint/secret config onto the row at dispatch: retries MUST
  read fresh config — rotation applying to pending deliveries and the
  durable endpoint disable are the spec's own mechanisms.

## Consequences

- Retries are observable and auditable from the ledger alone.
- The driver is Oban-free (directly testable with an HTTP double); the
  host-injected worker macro (ADR-0004) is the only Oban-bearing code,
  and it compiles only in hosts with Oban.
- `:sending` re-drive is at-least-once (documented; receiver-side
  webhook-id dedup is the SW contract).
