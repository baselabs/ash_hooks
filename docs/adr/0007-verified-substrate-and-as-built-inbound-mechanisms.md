# ADR-0007 — As-built inbound mechanisms on the verified substrate (G1–G5)

- **Status:** Accepted (2026-08-21)
- **Deciders:** operator (ratified), recorded by the outbound-fanout slice (#6)
  per the alignment audit's A1 directive (durable rationale for mechanisms
  that previously lived only in a gitignored intent addendum)

## Context

The inbound pipeline shipped through mechanisms chosen under probe pressure;
their rationale existed only in session artifacts. This ADR is the durable
record of the five named gaps (audit G1–G5), plus the outbound slice's own
substrate verification (Oban uniqueness, ADR-0004's long-open debt).

## Decision (record of as-built, each with its reason)

- **G1 — ash_sqlite is a dev/test-only substrate.** The fenced-ledger
  concurrency tests need storage-level uniqueness + conditional-update
  atomicity; sqlite provides them on a zero-infra leg (`deps` marked
  `only: [:dev, :test]`), never shipping in hex metadata, never constraining
  consumers. ETS was probed and cannot express either property.
- **G2 — the fence is a WHERE-gated query, not action-level guards.**
  `error()`-in-expression atomics are inexpressible on sqlite, and
  action-level `change filter(...)` is silently dropped on the atomic path —
  so conditional gates (claim/mark/renew) live in the query filters
  `AshHooks.Ingress` builds; injected actions are primitives only.
- **G3 — bounded transient busy retry.** exqlite surfaces busy/locked as
  string-wrapped `Ash.Error.Unknown.UnknownError`; a ≤2s jittered wall-clock
  retry, classified NARROWLY by that error text, converts transient
  contention into convergence. The dispatcher ports the same pattern (its
  own race test forced it: without the retry, concurrent re-dispatchers all
  surface :endpoint_error instead of converging on the CAS).
- **G4 — sync-mode-first.** The inbound pipeline is sync by default (verify →
  ingest → claim → handle → mark in the caller's request); async 202 mode
  rides the SAME machine steps via the delivery runtime (later slice).
- **G5 — client-writable uuid pk + id-compare classification.** The ledger
  injects a client-writable uuid primary key when the resource declares
  none; created/duplicate classification compares the surviving row's id
  against the caller-generated one — the only portable upsert
  classification that works without RETURNING extras on every data layer.

## Substrate verification (A4 — closes ADR-0004's open debt)

Verified first-hand against local `deps/oban` **2.23.1** (resolved by
`~> 2.20`) on 2026-08-21, before any delivery-runtime design:

- `Oban.Job` `@unique_fields ~w(args meta queue worker)a` — uniqueness
  fields are real job columns only; nested arg keys are NOT DB fields;
  `keys:` is the sanctioned sub-args mechanism (`validate_keys` demands
  `fields` ∋ `:args`|`:meta`). `fields: [:args], keys: [:endpoint_id,
  :event_uuid]` is a VALID config — ADR-0004's assertion CONFIRMED.
- Match semantics: jsonb containment `args @> taken_subset` within `states`
  for `period` seconds of `timestamp` (defaults `period: 60`,
  `states: :successful`, `timestamp: :inserted_at` — all three must be
  overridden for effect-once delivery).
- EDGE: `keys` declared but absent from a job's args → taken subset `%{}` →
  matches only empty-args jobs (`args <@ '{}'` on Postgres) — uniqueness
  silently degrades. The delivery args must ALWAYS carry both keys.
- Cross-engine: uniqueness implemented on Postgres (Basic `@>`/`<@` +
  advisory xact lock), MySQL (Dolphin `json_contains`), SQLite (Lite
  `json_extract`/`json_each`) — the package's sqlite test rig can exercise
  the same semantics.
- 2.23 adds compile-time warnings for incomplete explicit `:states` lists —
  prefer state groups.
- The PG floor: 2.21.0 raised it to PostgreSQL 14+ (PG12 EOL 2024-11); the
  2.23.1 README documents PG 14.0+ / MySQL 8.4+ / SQLite 3.37+.

## Consequences

- The five inbound mechanisms are now repo-durable; future sessions read
  reasons, not session archaeology.
- The outbound delivery identity `{endpoint_id, event_uuid}` deliberately
  coincides with the Oban uniqueness key pair — row identity and job
  identity are one concept.
