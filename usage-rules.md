# AshHooks usage rules

Guidance for maintainers and coding assistants working in applications that use
AshHooks 2.0.

## Build events from exact bytes

- Construct outbound events with `AshHooks.Event.new/1`. Pass the exact binary that will
  be signed and sent; do not pass a map and re-encode it later.
- Derive the event ID from the logical event's stable identity whenever the producer can
  run again. Include a revision or change ID when one source record emits several events.
  Reusing the event ID lets the ledger and receiver deduplicate repeated delivery.
- Do not construct `%AshHooks.Event{}` directly. Dispatch revalidates raw structs, but the
  constructor gives the caller the validation error before any row is written.
- Event IDs cannot contain dots, spaces, invalid UTF-8, or control characters because the
  ID is also serialized as the `webhook-id` header.

## Receive webhooks through the ledger

- Add `AshHooks` and `AshHooks.InboundDelivery` to the inbound ledger, declare the
  provider, and pass the raw request body to `AshHooks.Ingress.ingest/4`. Signature
  verification is over those exact bytes.
- Include every provider scope needed for uniqueness in `scope_identity`, and create the
  generated unique index in the database. The ledger is the deduplication boundary; do
  not add a separate seen-events table.
- A provider's `parse_event_type/1` classifies the verified payload; `handle_event/2`
  handles it. Built-in handlers return typed events. Implement application effects and
  their idempotency inside your own provider's `handle_event/2` callback.
- Provider identity resolution is ordered: an explicit declaration `event_id` extractor,
  then the provider's optional `event_identity/1`, then the raw-body digest when the
  provider has no identity callback. An implemented provider callback that rejects a
  malformed payload fails the ingest; it does not fall back silently.
- The low-level claim, renew, mark, and reap functions are for custom asynchronous
  pipelines. Preserve their token and lease values exactly; a stale owner must never
  write around a fence.

## Dispatch and drive outbound deliveries

- Add `AshHooks` to the emitting resource, declare `outbound`, and use
  `AshHooks.dispatch/4` for fanout. It creates one durable delivery obligation per
  matching enabled endpoint.
- `use AshHooks.Worker` is the supported Oban integration. Pass its `enqueue/2` callback
  to dispatch so each row receives a durable, uniquely identified trigger.
- `AshHooks.Delivery.run/2` is also a supported execution path. It drives an existing
  delivery row directly for queue-free hosts, custom schedulers, and one-row diagnostics.
  It does not create the row: dispatch first, then call `run/2` with the delivery identity
  and a complete configuration for the delivery resource, endpoint resource, secret
  resolver, retry limits, and backoff limits. Honor `{:snooze, seconds}` by scheduling the
  row again after that delay.
- A direct runner must impose the same outer scheduling discipline as the worker. Keep
  the attempt deadline finite and allow the result-write finalization window to complete.
- The row owns retries, attempt counts, send leases, and terminal state. Oban or a custom
  scheduler is a trigger only; do not add a second retry policy around the row.
- Delivery is at least once across a crash during transport. Receivers must deduplicate
  the stable `webhook-id`.

## Preserve durable ownership and recovery

- Do not edit `dispatch_source`, `dispatch_route`, attempt tokens, enqueue tokens, leases,
  or endpoint snapshots. Dispatch, direct execution, workers, and reconciliation use
  these fields to reject the wrong declaration, route, or stale owner.
- Run `AshHooks.reconcile_pending/3` periodically for every outbound declaration and
  tenant that uses queued delivery. It recovers stale pending rows, enqueue failures, due
  retries, expired sends, and interrupted endpoint disables. Future retries and live
  leases remain untouched.
- Keep the reconciliation cutoff beyond normal enqueue latency. The default is five
  minutes.
- Named worker callbacks carry a stable route automatically. An anonymous enqueue
  callback that must survive reconciliation needs a stable `enqueue_key`. An unkeyed
  anonymous callback cannot be reconstructed and is reported as `:unresolved_route`.
- Custom enqueue callbacks must be idempotent. The enqueue effect may succeed before a
  claimant crashes and releases its lease.
- A 410 response first records `:disable_pending` with an endpoint snapshot. Recovery may
  complete that disable only if the endpoint still matches the snapshot; an old response
  cannot disable replacement configuration.

## Treat identity upgrades as data migrations

- When adopting a provider-defined identity for rows created with the former raw-body
  digest, first call `AshHooks.Ingress.plan_legacy_identity_adoption/3` and review its
  unresolved rows, conflicts, representative choices, and before/after keys.
- Quiesce ingress and reapers before calling
  `AshHooks.Ingress.adopt_legacy_identity/3` with `quiesced?: true`. Use the same scope,
  tenant, and canonical-ID overrides that were reviewed in the plan.
- Adoption keeps one representative for each canonical identity. Sibling audit rows stay
  stored with their original payload and digest and become terminal `:superseded`; they
  are never reaped into handler execution.
- Never rewrite provider identities or mark rows superseded with ad hoc updates.

## Keep resource references and tenancy consistent

- Endpoint and subscription resources each need one UUID-storage-compatible primary key;
  the attribute may have any name and may use `:uuid_v7`. The DSL rejects composite or
  non-UUID keys where scalar delivery references cannot represent them.
- Delivery and inbound ledgers may use consumer-defined or composite primary keys. Use
  the package's primary-key helpers and full key maps rather than assuming a field named
  `id`.
- In a multitenant application, use the same attribute-tenancy contract on every resource
  touched by an operation and pass the tenant to every entry point. Global tenancy is
  rejected. Missing or mismatched tenancy fails before data access.
- Queue arguments serialize the row tenant and full delivery key so a restart can recover
  the same scope. Do not replace them with ambient process context.

## Keep secrets, responses, and retention bounded

- Secrets are resolvers, never literals: use `{module, function, args}`, `{:app_env,
  path}`, a zero-arity function, or a tenant-aware one-arity function. Persist only secret
  references.
- The default HTTP adapter validates destinations at send time, pins the validated
  address, never follows redirects, rejects unsafe headers, and applies one finite deadline across
  DNS, connect, send, and reads. Keep these guarantees when supplying a custom adapter.
- Response snippets store no body bytes by default. Enable `snippet_capture: true` only
  for an explicit diagnostic run. A custom snippet redactor receives the raw captured
  bytes and must return a binary or `nil`; a crash or invalid return falls back to the
  package's sanitized summary.
- Use `AshHooks.Ingress.prune/2` and `AshHooks.Delivery.prune/2` for bounded retention.
  Only terminal rows are deleted. Inbound `:superseded` rows are terminal and remain
  available for audit until the configured retention pass removes them.
- The package injects no read policy. Define narrow consumer actions and Ash policies for
  ledger, endpoint, and subscription access. Avoid broad `accept` lists on internal state
  fields.

## Common mistakes

- Decoding JSON before capturing the raw request body used by the provider signature.
- Generating a new event ID each time the same source record is dispatched.
- Calling `Delivery.run/2` without handling `{:snooze, seconds}`.
- Running queued delivery without scheduling `reconcile_pending/3`.
- Using an anonymous enqueue callback without a stable `enqueue_key` when recovery is
  required.
- Treating a built-in provider parser as the application's domain handler.
- Reading or updating a row through an assumed `.id` instead of its declared primary key.
- Registering a telemetry prefix instead of the complete event name expected by
  `:telemetry.attach_many/4`.
