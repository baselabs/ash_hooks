# ash_hooks usage rules

For AI assistants working in codebases that use ash_hooks.

## When to use what

- Receiving webhooks: put `AshHooks` + `AshHooks.InboundDelivery` on a
  ledger resource, declare `inbound :provider` sources, and drive
  `AshHooks.Ingress.ingest/4` — it verifies, persists, dedups, claims,
  invokes the provider handler, and marks the outcome in one call. The
  low-level lease primitives (`claim_delivery/3`, `mark_processed/4`,
  `mark_failed/6`, `renew/4`, `reap/2`) are public for custom async
  pipelines; ingest/4 itself drives the row to a terminal or
  re-driveable state in one call (`:failed_retryable` rows are
  non-terminal — the lease machine re-drives them). The ledger's unique
  index IS the dedup — never build your own seen-table.
- Sending webhooks: put `AshHooks` on the emitting resource with an
  `outbound :event` declaration; the subscription/endpoint/delivery
  extensions carry the fanout; `use AshHooks.Worker` in the consuming
  app is the Oban seam; `AshHooks.dispatch/4` is the only entry point.
- Retention: `Ingress.prune/2` / `Delivery.prune/2` delete TERMINAL
  rows only (needs `timestamps()` on the resource); redacting a claimed
  row's payload uses `Ingress.redact_payload/5` — never write the
  payload column directly.
- Never call `AshHooks.Delivery.run/2` in normal flow — it is the
  runtime the worker drives. The exception: a one-row diagnostic
  re-drive with `snippet_capture: true`.
- Multi-tenant apps: declare the SAME attribute multitenancy
  (`strategy :attribute, attribute: <attr>` — `global?: true` is
  rejected) on all four resources and pass `:tenant` /
  `ctx[:tenant]` to every entry point. Never bypass the threading with
  raw queries against the ledgers; a tenant-less call against a
  multitenant resource fails closed (`{:error, :tenant_required}`) by
  design. Sweeps are per-tenant (`reap_all`/`prune_all` for a tenant
  list); stranded `:pending` rows go through
  `AshHooks.reconcile_pending/3`, never hand-rolled updates.

## Hard rules (package floors — do not work around)

- Secrets are SOURCES, never literals: `{m, f, a}`, `{:app_env, path}`,
  a 0-arity function, or a 1-arity function receiving the tenant
  (multi-tenant ledgers). A literal binary secret is rejected at DSL
  parse time (ADR-0005).
- The endpoint `url` accepts only public http(s) destinations —
  private/loopback/link-local/metadata literals are rejected at
  registration and re-checked at send time (with DNS re-resolution).
- Response snippets store NO body bytes by default. Body capture is a
  per-call `snippet_capture: true` in the `AshHooks.Delivery.run/2`
  config (deliberately not a worker-macro option); captured bodies pass
  the in-package redaction floor. Do not copy response bodies into your
  own columns — reuse `AshHooks.Delivery.redact/1` if you must persist
  response-derived text.
- A `snippet_redactor` callback ({m,f} in the worker macro, or a 1-arity
  fn in the run/2 config) sees the RAW captured body and must return
  `binary | nil`; a crash or invalid return degrades to the sanitized
  summary, never raw bytes.
- Telemetry events carry ids/integers/fixed atoms/classified reasons
  only. If you need secret identity in an event, use
  `AshHooks.Telemetry.fingerprint/1` (8-hex) — never the material.

## Patterns

- Inbound controller: read the RAW body before any JSON decode (the
  signature is over the exact bytes), pass `signature` + `headers` +
  `scope` in the ctx map.
- Oban worker: always `use AshHooks.Worker` (the Oban beam compiles only
  where Oban exists); pass the generated `enqueue/2` as the dispatch
  `enqueue:` seam — it carries the effect-once job uniqueness.
- Retries are ROW-owned: don't add Oban-level retry logic around
  deliveries; the row's attempts/backoff/ceiling + `Retry-After`
  handling are the machine.
- Observability: attach telemetry handlers with `attach_many` over the
  exact event names (see `AshHooks.Telemetry` for the full list —
  prefix attaches never fire).

## Common mistakes

- Declaring `replay_window_seconds` for a provider without a timestamp
  header — the DSL verifier rejects it.
- Reading the delivery row's fields through consumer actions —
  `response_status`/`response_snippet`/`next_attempt_at` are
  `writable?: false` (no consumer action accepts them anywhere);
  `attempts`/`last_error` are excluded from the INJECTED actions' accept
  lists only — a consumer-defined action with a broad accept list could
  write them, so keep consumer actions narrow; build read views
  instead.
- Expecting `:telemetry` prefix handlers to fire: `execute/3` matches
  exact names — subscribe to the full event name, not a prefix.
