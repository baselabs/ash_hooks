# Upgrading

## 3.0.0 → 3.1.0

The Ash floor rises from 3.34.3 to 3.37.2, because three published advisories
affect Ash releases the old floor admitted (EEF-CVE-2026-101028, -114214 and
-96581). If your lock holds Ash below 3.37.2, update Ash first:

```sh
mix deps.update ash
```

Nothing else changes for this reason: no schema change and no API change.

`AshHooks.Plug` is new and optional. An existing controller that calls
`AshHooks.Ingress.ingest/4` keeps working unchanged. To move to the plug, forward
the webhook route to it and delete the controller; the
[README](README.md#mounting-the-plug) shows both the fixed-source and the
resolver form. If that controller passes `ctx.signature` itself for a hand-written
provider, set the plug's `signature_header:` to the header it read. Code that
read `conn.private[:ash_hooks_raw_body]` should call
`AshHooks.BodyReader.raw_body/1` instead; the key is internal.

Event-log replay takes `declaration: {Emitter, :event_name}` to bind new deliveries
to the same declaration and queue contract as dispatch. Enable `resend_tracking :on`
to persist the requester and request time. The enqueue callback receives the created
delivery and its event; terminal replays carry the tenant through resend.

Health sweeps enforce `warning_interval_seconds` (default 60) from the stored
warning time. Counts and telemetry reflect committed marker and disable writes.
Delivery pruning with `attempts:` requires transaction-capable resources and rolls
back a batch if history deletion fails. For SQLite, enable `write_transactions?/0`
on the repo. Early key retirement records its actual time; a previous key continues
to sign until its stored reference is removed.

Every inbound ledger now has a generated `:record_malformed` create action.
It uses the same accept list, unique identity, and no-touch upsert as `:ingest`.
When a verified body cannot decode to a map or list and its event identity
resolves, ingress writes it with this action: the new row has the placeholder
payload `%{}`, status `:failed_permanent`, and error class `"malformed_payload"`,
is never claimed or handled, and keeps attempts and fencing token at 0. A
provider identity callback that rejects the placeholder refuses the request
before `:record_malformed` runs, as before; with `ingress_tracking :on`, ingress
attempts to record the refusal as a rejection row. A duplicate still drives the
surviving row's stored payload. No schema migration is required; restrict direct access to this action
along with the other machine actions.

A ledger written by an earlier version can hold a nonterminal row whose payload
is the placeholder `%{}` from an undecodable body: a `:received` or
`:failed_retryable` row, which the next duplicate delivery claims, or a
`:claimed` row with an expired lease, which `AshHooks.Ingress.reap/2` drives.
Both handle the stored payload. The upgrade does not find or repair these rows,
and `%{}` can also be a real payload. Review candidates for each tenant: with
`:inserted_at` and `:id` on the ledger, page through `AshHooks.Ingress.list/2`
with `status: [:received, :failed_retryable, :claimed]`, passing each
`next_cursor` as `after:` until it is `nil`; otherwise read the ledger with the
same status filter. Then decide how to handle each row.

`use AshHooks.Worker` now refuses at compile time a `:transport` that is not
`nil` or `{module, function}`, and a function literal (`fn ... end` or
`&fun/arity`) for `:delivery_headers` or `:certificate_pin`. A worker that
passed a function for `:transport` compiled before but sent every delivery
through the HTTP adapter; move the function into a module and pass
`{module, function}`.

## Versions >= 2.0.1 and < 3.0.0 → 3.0.0

3.0.0 makes inbound verification generic. It removes the vendor-specific
verifier modules and the name-to-module convention, and adds a configuration
layer that expresses each removed scheme, and many others, in one small module
in your application. There are two breaking changes; nothing else changes shape.
No migration and no dependency change is needed.

If you are upgrading from a release >= 2.0.1 and < 3.0.0, also read the section for each
release you skip.

### Breaking: every inbound declaration needs `provider`

Versions >= 2.0.1 and < 3.0.0 resolved a missing `provider` to `AshHooks.Provider.<CamelizedName>`, so
an inbound name selected a built-in provider by convention. That convention is
gone. A declaration without `provider` fails to compile with a message naming
the fix:

Replace `:existing_source` with your existing inbound name; do not rename it.

<!-- tested: upgrade-source-in-application -->
```elixir
webhooks do
  inbound :existing_source do
    provider MyApp.Webhooks.ExistingSource
    secret {:app_env, [:my_app, :webhook_secret]}
  end
end
```

**Keep each inbound name exactly as it was.** The name is stored in the ledger's
`provider` column and is part of every deduplication identity, so renaming a
source would let already-recorded deliveries be processed again.

### Breaking: the vendor verifier modules are removed

These modules no longer exist: `AshHooks.Provider.ComplyCube` (with
`ComplyCube.Event`), `AshHooks.Provider.HubSpotV3` (with `HubSpotV3.Event` and
`decode_request_uri/1`), `AshHooks.Provider.Twilio`, `AshHooks.Provider.Stripe`,
`AshHooks.Provider.Shopify`, `AshHooks.Provider.WooCommerce`,
`AshHooks.Provider.Shippo`, `AshHooks.Provider.EasyPost`,
`AshHooks.Provider.Magento2`, `AshHooks.Provider.BigCommerce`,
`AshHooks.Provider.Ecwid`, `AshHooks.Provider.Squarespace`, and
`AshHooks.Provider.Wix`.

Replace each with a provider module in your application. Most need only
configuration:

This application-defined example verifies a base64 HMAC of the raw body.

<!-- tested: upgrade-shop-provider -->
```elixir
defmodule MyApp.Webhooks.Shop do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-shop-signature"},
      encoding: :base64
    ]
end
```

Define an application provider from the sender's current signing documentation.
The [generic verification guide](documentation/tutorials/verify-any-sender.md)
explains supported signature shapes. Preserve existing source names, event-type
mappings, and delivery identities. Consult the provider source shipped in
ash_hooks 2.3.0 when preserving an existing mapping. The historical
[event-type mapping source](https://github.com/baselabs/ash_hooks/blob/v2.3.0/lib/ash_hooks/provider/comply_cube.ex)
and [batch-provider source](https://github.com/baselabs/ash_hooks/blob/v2.3.0/lib/ash_hooks/provider/hub_spot_v3.ex)
remain available in the public repository.

When replacing a raw-body identity with a verified-payload identity, plan and
apply legacy identity adoption before resuming ingress. Preserve the former
provider's identity unless intentionally migrating it; an invalid provider
identity fails ingestion rather than falling back to the body digest.

### What stays the same

- `AshHooks.Provider`, every callback, and `default_verify_signature/4`.
  `signature_source/0` gains a third value, `:request`, for providers that read
  their own signature from the headers; `:header` (the default) and `:body` keep
  their meaning.
- `AshHooks.Provider.Hmac` keeps its options and behavior, and its `:algorithm`
  option now also accepts `:sha384` and `:sha512`. New code can use
  `use AshHooks.Provider, verify: [...]`, which covers the same ground and more.
- `AshHooks.Provider.Event` and `AshHooks.Provider.Mock`.
- Form bodies, batch payloads, tenant-aware `paused` and `previous_secret`,
  retry-status selection, certificate pins, host delivery headers, outbound
  signing (`AshHooks.Signing`), and every resource, column, action, and
  telemetry event.

### New

- Pass `headers: conn.req_headers` (the ordered list) instead of building a map.
  Providers then receive every header line in `ctx.header_list`, and repeated
  lines are joined with `", "` in `ctx.headers`. A map you pass is still delivered
  unchanged, but it has already lost repeated lines, so a provider that reads a
  header that can repeat should read `ctx.header_list`. If you passed a list in
  releases >= 2.0.1 and < 3.0.0, outside the documented map type, providers now receive a map in
  `ctx.headers`.
- A configured `:jws_body` provider deduplicates on its verified payload
  (`Scheme.payload_identity/1`).
- `use AshHooks.Provider, verify: [...]` generates a provider from
  configuration. `AshHooks.Provider.Scheme` documents every option and exposes
  `Scheme.verify/4` for direct calls.
- `AshHooks.Provider.Signature` is now public: `hmac/4`, `rsa/4`, `ecdsa/4`,
  `ed25519/4`, `jws/3`, `compare/2`, `header/2`, and `check_timestamp/3`.

## 2.2.1 → 2.3.0

**Nothing is required for existing adopters.** No migration, dependency, or
existing default changes. The new behavior is opt-in, apart from fixing the
documented tenant-aware `paused` and `previous_secret` callbacks: one-argument
callbacks receive the resolved tenant on multitenant ledgers. Calls without a
tenant behave as before. Zero-argument, `{module, function, args}` and app-env
sources keep working. `previous_secret` app-env sources accept the documented
binary value; the `{:ok, key}` environment shape also works.

- Opt into URL-encoded ingress with `body_format :form` on an inbound declaration
  or a provider's optional `body_format/0`. The raw bytes still reach signature
  verification unchanged. JSON remains the default. Providers can decode a signed
  body envelope with `decode_payload/1` and declare it with `signature_source/0`.
- 2.3.0 added vendor verifier modules. 3.0.0 removes them; configure your own
  provider instead, as described in the 3.0.0 section above.
- Host-owned emitters can use `AshHooks.Provider.Hmac.verify_signature/4` with
  trusted options for header, algorithm, hex or base64, timestamp tolerance,
  canonical input, and overlap keys.
- Set `retryable_statuses` on the worker or direct-run config to replace the
  ordinary HTTP retry set. Omit it to keep the default. 2xx, redirects, and 410
  retain their existing rules; configured retry responses honor `Retry-After`.
- Add `delivery_headers: {module, function}` on the worker/direct-run config.
  It receives `(delivery, endpoint, tenant)` and returns binary header pairs.
  Direct configuration also accepts a map/list or function. Package-owned signing,
  content-type, and framing headers cannot be overridden, regardless of case.
- Optional certificate pins use `certificate_pin: {module, function}` on a worker
  or direct run, resolving `(endpoint, tenant)` to a pin or `nil`. A host-wide
  pin can also live in `http_opts[:certificate_pin]`. Supported pins are exact
  DER leaf certificate, SHA-256 of that DER, or SHA-256 of DER SubjectPublicKeyInfo.
  Pins require HTTPS and the bounded adapter; normal TLS and SSRF checks stay on.
  Mismatch and configuration failures are non-retryable and send no body bytes.

See [README.md](README.md) for examples.

## 2.2.0 → 2.2.1

- **`auto_disable` declarants gain the `disable_warned_at` column.** The
  warning-first fix stores the standing "a warning sweep has fired" fact
  on the endpoint; declaring `auto_disable` now injects the marker column
  and its machine action; add the column to the endpoint table's
  migration when you upgrade. A disable lands one sweep after the first
  qualifying warning, which is the behavior 2.2.0's moduledoc already
  described.

## 2.1.0 → 2.2.0

New OPTIONAL surface: nothing changes for an install that adopts none of
it: no existing column, action, event, or default behavior moves.

- **Attempt history (opt-in).** To record every delivery attempt (time,
  outcome, classified reason, HTTP status, latency, the signing key
  reference), create a resource with the new `AshHooks.OutboundAttempt`
  extension, migrate its table (the tutorial carries the DDL, including the
  `unique_attempt` index on `[:delivery_pk, :attempt]`), and pass
  `attempts: MyApp.OutboundAttempt` to `use AshHooks.Worker` (or the direct
  `AshHooks.Delivery.run/2` config). The runtime writes rows through the
  injected `:record` action; cover it with an action-specific policy like
  every other injected write action.
- **Per-endpoint response capture (opt-in).** Declaring
  `response_capture_attributes :on` on the endpoint resource injects four
  columns (`response_capture`, `response_capture_max_bytes`,
  `response_capture_retention_seconds`, `response_header_allowlist`);
  migrate them when you declare it. Capture remains per-row opt-in
  (`response_capture: true`); captured bytes are bounded, redacted, and
  header capture is allowlist-only.
- **Delivery-log queries.** `AshHooks.Delivery.list/2` and
  `AshHooks.OutboundAttempt.list/2` filter by endpoint, status/outcome,
  event type, and time range with keyset pagination; the delivery resource
  needs `timestamps()` and an `:id` attribute for them.
- **Test-send flagging (opt-in).** Declaring `test_tracking :on` under
  `outbound_delivery` injects the `test` boolean column; migrate it when
  you declare it. Attempt-history resources gain the `test` column in
  this release (the extension itself is new in 2.2).
- **Inbound tracking (opt-in).** Declaring `ingress_tracking :on` on an
  inbound ledger injects the `duplicates` counter column and the
  `failed_verification` status row (payload-less); migrate the column
  when you declare it. `previous_secret`/`paused` are declaration-level
  options (no migration).
- **The event log (opt-in).** Create a resource with the new
  `AshHooks.OutboundEvent` extension (needs `timestamps()`; the migration
  carries the table plus the `unique_event` index on `[:event_uuid]`),
  then declare `events YourResource` on each outbound declaration that
  should record. Nothing records without the declaration.
- **Subscription attribute filters (opt-in).** Declaring a nonempty
  `filter_attributes` list on the subscription resource injects the
  `event_filters` column; migrate it when you declare it.
- **Payload-version pinning (opt-in).** Declaring `version_pinning :on`
  on the endpoint resource injects the `pinned_payload_version` column;
  migrate it when you declare it. Endpoints without a pin, or pinned to the
  declaration's current `version`, receive the dispatch payload; other pins
  select the matching `payload_versions` builder, and a pin on a version
  with no builder fails that endpoint before a delivery row is created.
- **Secret rolling (opt-in).** Declaring `key_lifecycle :on` on the
  endpoint resource injects six timestamp columns
  (`secret_created_at`, `secret_first_used_at`, `secret_retired_at`,
  `previous_secret_created_at`, `previous_secret_first_used_at`,
  `previous_secret_retired_at`); migrate them when you declare it, and
  backfill `secret_created_at` for incumbent keys whose creation time you
  know. Rolling then works through `AshHooks.Endpoint.roll_secret/2` and
  the expiry sweeps.
- **Resend and bulk replay (opt-in).** Declaring `resend_tracking :on`
  under `outbound_delivery` injects four machine columns
  (`resend_baseline`, `resend_count`, `last_resend_by`, `last_resend_at`)
  and unlocks `AshHooks.Delivery.resend/2` / `replay/2`. Migrate the columns
  when you declare it. Attempt ceilings are now
  series ceilings: a resent row's ladder restarts at its baseline while
  the lifetime `attempts` counter never resets (attempt-history identity
  stays sound). Resources without the columns keep the exact pre-2.2
  ceiling semantics.

## 2.0.4 → 2.1.0

No schema or DSL changes. Two observable deltas:

- **Unresolvable DNS at the send-time destination check now retries.** In
  2.0.4 a hostname that failed to resolve (resolver outage, congestion past
  the 2-second resolution ceiling, or a dead domain) dead-lettered
  immediately as `unsafe_destination` at `attempts == 1`. In 2.1.0 it
  retries as transport and dead-letters at the row ceiling carrying an
  honest label: `nxdomain` (every queried address family answered
  authoritatively negative) or `resolve_timeout` (outage, congestion,
  mixed evidence); the HTTP adapter's umbrella for the same failures is
  `unresolved_host` (all three are in the telemetry reason vocabulary).
  A validated-unsafe answer (private/special-purpose IP) still dead-letters
  immediately as `unsafe_destination`. If you branched on the immediate
  dead-letter to detect DNS-dark endpoints, read the labeled rows off the
  ceiling instead.
- **`use AshHooks.Worker` refuses misfit budgets at compile time.** Oban's
  `:max_attempts` must exceed `:delivery_max_attempts`; a literal
  `:http_opts` `timeout:` must stay below `:attempt_timeout`. The macro checks positive
  attempt, finalization, delivery-attempt, backoff, and Retry-After budgets; all configured
  budgets must be positive; `:max_backoff_seconds` must be at
  least `:base_backoff_seconds`. A literal `:http_opts`
  `validate_destination: false` refuses to compile outside `:test` (it is
  the loopback-listener test seam; with it baked in, the driver's send-time
  check is the only remaining SSRF layer). Configs that compiled in 2.0.4
  while silently truncating the retry ladder, walling off slow sends, or
  disabling adapter pinning now raise `ArgumentError`.

## Versions >= 1.0.0 and < 2.0.0 → 2.0.1

Version 2.0.1 changes the durable delivery schema and the default batch identity.
Drain old jobs and migrate before activating the new runtime. Workers from before and after 2.0.1 running together against one ledger are unsupported.

### Ordered deployment

1. Quiesce outbound producers, ingress, workers, inbound reapers, and recovery
   schedulers. Drain Oban jobs created before 2.0.1. Record pending rows, retry times,
   tenant partitions, declaration ownership, and the current queue binding.
2. Upgrade to `{:ash_hooks, "~> 2.0"}` with Ash `>= 3.34.3 and < 4.0.0-0`. Generate
   and inspect the AshPostgres migration for every resource carrying either
   delivery extension. Preserve existing endpoint/event and inbound dedup indexes.
3. Add the outbound columns below and extend any database status constraint to
   admit `disable_pending`. Add `superseded` to the inbound status constraint.
   New generated actions are machine primitives: keep application write actions
   narrow and update any explicit action policies before activation.
4. Backfill each existing outbound row's `dispatch_source` and `dispatch_route`
   from its actual emitting declaration, endpoint resource, and enqueue binding.
   Keep attempts and `next_attempt_at`; expired sends need recovery, rather than
   counter resets. Unresolved declaration or route mappings block activation.
5. If a declaration using the former batch provider uses the former digest default, adopt retained
   identities as described below while ingress and reapers remain quiesced.
   Declarations with an explicit `event_id` extractor keep that extractor.
6. Deploy all 2.0 application nodes/workers together. Enable the periodic
   recovery call for each declaration and tenant, then resume ingress and producers.
   Observe row transitions, persisted runnable jobs, endpoint-disable events, and
   a signed delivery through the actual receiver.

### Outbound columns and ownership

| Attribute | Ash type | Migration requirements |
| --- | --- | --- |
| `dispatch_source` | `:string` | Non-null; max length 1,024; explicit legacy backfill |
| `dispatch_route` | `:string` | Non-null; max length 1,024; explicit legacy backfill |
| `attempt_token` | `:uuid` | Nullable; non-writable |
| `send_lease_expires_at` | `:utc_datetime_usec` | Nullable; non-writable |
| `enqueue_token` | `:uuid` | Nullable; non-writable |
| `enqueue_lease_expires_at` | `:utc_datetime_usec` | Nullable; non-writable |
| `endpoint_snapshot` | `:map` | Nullable; non-writable; JSON storage |

For a declaration and named worker, derive backfill values through
`AshHooks.OutboundBinding.source/3` and `named_route/2`:

<!-- tested: upgrade-binding-in-application -->
```elixir
source = AshHooks.OutboundBinding.source(MyApp.Order, :order_paid, MyApp.WebhookEndpoint)
route = AshHooks.OutboundBinding.named_route(MyApp.WebhookDeliveryWorker, :enqueue)
```

Apply those values only to the reviewed declaration/tenant partition. The
declaration and endpoint module names are part of the versioned identity; renames
require an explicit mapping. Do not infer ownership from current subscriptions.
The default `"v1:direct:unbound"` / `"v1:route:unbound"` markers preserve direct
`:dispatch` action compatibility; they do not identify a legacy declaration.

Named MFA enqueue callbacks and equivalent external captures share a route.
Anonymous callbacks still dispatch; use a stable `enqueue_key` to enable automatic
recovery. An unkeyed anonymous route requires an explicit host mapping. A deferred
declaration dispatched with `enqueue: nil` can bind its route once during recovery.
Keep any keyed callback bound to the same implementation in the host application.

Send claims and result writes use a UUID token, separate from the writable
accounting counter `attempts`. A live send lease blocks competing claims; stale
results cannot mark success, retry, or disable an endpoint. Delivery over the
network remains **at-least-once**: a peer may accept a request before a process
dies or its lease expires. Receivers and inbound handlers need idempotency.

Lease timestamps use application UTC time. Synchronize clocks across application
nodes; expiry and due-time decisions require that deployment prerequisite. The
default attempt budget is 25 seconds plus a 5-second finalization allowance;
the generated Oban timeout is 35 seconds and must exceed their sum. Configure
`attempt_timeout`, `finalization_allowance`, and `timeout` together.

`reconcile_pending/3` now also recovers due retryable failures, expired sends,
enqueue failures, and pending-disable obligations. It preserves attempts and
retry timestamps. Call it periodically per declaration/tenant using the matching
durable route. A 410 stores `disable_pending` before the endpoint write; it is
not terminal until the matching old endpoint configuration is disabled, gone,
or replaced. A storage error keeps that obligation recoverable without resending.

### Adopt a canonical provider identity

Implement `event_identity/1` in the application provider before planning adoption.
An explicit declaration `event_id` extractor takes precedence over that callback.
Invalid extractor results use the raw-body digest. An invalid provider identity
fails ingestion.

The ledger must declare `timestamps()` and have matching timestamp columns.
For AshSqlite, enable write transactions with the repo's `write_transactions?/0`
callback and configure a pool and busy timeout suitable for writes. Adoption
returns `{:error, :transactions_not_supported}` when the data layer does not
advertise transaction support.
The following fragment runs inside a complete application with a scoped,
multitenant ledger, its provider, and a retained legacy row. `tenant` and
`account_id` select the partition being migrated. Stop ingress and reapers,
plan every partition, and retain each audit before applying:

<!-- tested: upgrade-adoption-in-application -->
```elixir
opts = [tenant: tenant, scope: %{account_id: account_id}]
{:ok, plan} = AshHooks.Ingress.plan_legacy_identity_adoption(MyApp.InboundLedger, :existing_source, opts)
# Review plan.audit; resolve every item in plan.unresolved and plan.conflicts.
{:ok, applied} =
  AshHooks.Ingress.adopt_legacy_identity(MyApp.InboundLedger, :existing_source, Keyword.put(opts, :quiesced?, true))
```

Within a canonical group the representative is processed first, then recoverable,
then permanently failed, with deterministic insertion/key tie-breaking. The
representative receives the canonical identity; siblings become terminal
`:superseded`. Every original payload and digest stays stored. The returned audit
contains before/after keys, identities, statuses, digests, and representative
mapping; persist it in your own upgrade records. Adoption never invokes a handler.
Redacted/unavailable payloads require explicit `canonical_ids` mappings, keyed by
the old external event ID. Unresolved rows and canonical-identity conflicts block
the transaction. The data layer must support transactions; otherwise adoption returns
`{:error, :transactions_not_supported}` without changing rows. Re-plan after applying
to verify stable state. Run each
partition with ingress/reapers stopped; `quiesced?: true` is an assertion by the
operator, not an application-wide lock.

Return a successful provider acknowledgment for `:processed`,
`:failed_permanent`, and `:superseded`. Send permanent errors to your operator
surface; repeated provider retries cannot repair a terminal row.

### Resource and security compatibility

- Ledger operations support complete custom primary-key maps. Endpoint and
  subscription references require a single UUID-storage-compatible key, including
  a renamed UUID/UUIDv7 key. Incompatible/composite reference keys fail at compile.
  Every ledger key component must be generated, defaulted, or supplied by its
  injected create action; unavailable key inputs fail at compile.
- Endpoint mapped enabled/disabled values are cast using the attribute's real
  type/constraints. Empty enabled values, semantic overlap, invalid values, and
  mapping any primary-key attribute fail at compile.
- Event IDs and HTTP headers reject control bytes and invalid UTF-8. Dispatch
  validates IDs on manually constructed event structs too. Event types remain
  nonempty atom/string values bounded to 255 bytes. Arbitrary telemetry reason text becomes
  `unclassified`; use the documented reason vocabulary.
- The default HTTP adapter shares one deadline across DNS, connect, send, and reads.
  Its body cap ends reading immediately; interim 1xx responses precede the final
  response. Special-purpose IP ranges are rejected and IPv6 Host values are bracketed.

## 1.2.1 → 1.3.0

**Nothing breaks and nothing is required.** This release is additive:
new per-resource DSL options (`payload_attribute`, `prune_action`, the
`endpoint` mapping section), docs, and CI. Two behavior notes worth
knowing even if you change nothing:

1. **Generated (non-writable) primary keys now compile.** Resources
   declaring `uuid_v7_primary_key` (or any non-writable `:id`) previously
   failed Ash's `ValidateAccept` on the injected `:dispatch`/`:ingest`
   accept lists. Those resources now compile and classify
   created/duplicate by an identity pre-read. Storage uniqueness preserves the
   row; it does not guarantee one network side effect. Version 2.0 adds durable
   attempt and enqueue ownership. Receivers still need webhook-ID deduplication.
2. **The send path dead-letters an endpoint whose status is anything
   other than `:enabled`** (previously only an exact `:disabled`
   dead-lettered). Only affects consumers who redeclared `status` with
   extra values, enforcing the fail-closed direction.

New options, all opt-in: rename the exact-bytes column
(`payload_attribute`), omit the retention destroy action
(`prune_action :none`), map the durable enable/disable onto your own
switch (`endpoint do status_attribute ... end`), and atom-typed
subscription registers now match. The README's "Fitting the extensions
to your domain" section shows each.

## 1.1.1 → 1.2.0 or 1.2.1

### Multi-tenancy is available and opt-in

Declare the same attribute multitenancy contract on every resource used by an
operation, including optional attempt-history and event-log resources. If you do, read the adoption
checklist (`documentation/tutorials/tenancy-adoption-checklist.md`);
the ordered transition for populated tables is **backfill the tenant
attribute → regenerate identity indexes → enable multitenant
dispatch**. A NULL-tenant legacy row forms a shadow partition: new
tenant-bearing upserts create parallel rows and allow repeated processing of
the same logical event.

Two obligations for multi-tenant adopters:

1. **Drain Oban jobs created before 1.2.0 before serving multitenant
   dispatch.** Pre-tenancy job args carry no tenant and fail closed
   (`{:error, :tenant_required}`) against multitenant resources.
   This is correct, but noisy. Drain first.
2. **String tenants are the supported job-args shape.** The worker
   serializes the row's tenant into Oban args (JSON), inverting the
   attribute value through the resource's `tenant_from_attribute`. A
   custom `parse_attribute` should pair with `tenant_from_attribute`
   (the default inverse is identity).

New heads are additive: `reap/2`, `redact_payload/5`, `mark_processed/4`,
`mark_failed/6`, `renew/4`, `claim_delivery/3` gained an optional
`opts` (or `:tenant` for the prunes); all prior arities keep working.
The `%{endpoint_id, subscription_id, status, error}` dispatch result
container is now a typespec'd public contract with one NEW status:
`:reconciled`.

## 1.0.4 → 1.1.0 or 1.1.1

### Elixir `~> 1.20` required; previously `~> 1.17`

The supported Elixir window is now `~> 1.20`. Applications resolving
ash_hooks on Elixir 1.17 to 1.19 get a hard resolver error at deps
loadpaths instead of a compile. An increase in the minimum supported version ships as a minor release, so a `~> 1.0` pin will happily resolve
1.1.0 and then fail resolution on old Elixirs. If you cannot move to
Elixir 1.20 yet, pin the floor release instead:

<!-- tested: upgrade-dependency-1-0-4 -->
```elixir
{:ash_hooks, "~> 1.0.4"}
```

## 1.0.3 → 1.0.4

Behavior corrections (all also under "Fixed" in the CHANGELOG; no API change):

### 1. Event ids and types are bounded by BYTES, not characters

`AshHooks.Event.new/1` and dispatch previously accepted ids and types up to
255 *characters* (graphemes). Long multi-byte values could pass that check
and then fail the delivery write; under Ash 3.33's `:codepoints` counting,
every endpoint's dispatch errored on an event the library had validated.
Ids and types are now rejected above 255 **bytes** at `Event.new/1`, with a
clear error. If you build ids or types from multibyte text, a value of at
most 255 graphemes can exceed 255 bytes; such values now fail at
construction. Previously they passed construction, and those over the
ledger's 255-codepoint limit failed later, less clearly, at dispatch.

### 2. Captured snippets and error fields are byte-capped

The 2048-character snippet cap and 255-character error-summary caps counted
graphemes; they now cap **bytes** (on a codepoint boundary). Captured
diagnostic snippets of multi-byte content come out slightly shorter, and a
hostile response body built from combining characters can no longer crash
the post-send ledger write; the same applies to thrown/exit error
classifications.

### 3. Handler failures with invalid-UTF-8 binaries still record

A handler returning `{:error, :retry | :permanent, term}` where `term` is
invalid UTF-8 previously made the failure-recording write itself fail, so
the delivery stayed re-drivable with no record. It now records `[binary]`
as the error class.

## Required `default_string_length_count` configuration

Every Ash version supported by ash_hooks 3.1.0 requires this configuration
before compiling resources. ash_hooks writes no `:ash` configuration for you. Set it
in your application's `config/config.exs`:

<!-- tested: upgrade-string-config-in-application -->
```elixir
# Recommended: counts unicode codepoints, so max_length bounds value
# size and validation matches how SQL data layers count.
config :ash, default_string_length_count: :codepoints

# Keeps pre-3.33 behavior: graphemes are counted when validating in
# Elixir; a single grapheme can carry unboundedly many codepoints, so
# max_length does not bound the size of a value.
config :ash, default_string_length_count: :mixed
```

ash_hooks works under both. One nuance worth knowing: the fields
ash_hooks injects onto ledger and delivery resources carry `max_length`
constraints (event ids and error summaries at 255, response snippets at
2048). Under `:codepoints` those bounds limit codepoints; under
`:mixed`, Elixir-side validation of the same constraints counts
graphemes, the exact tradeoff Ash documents for your own attributes.
The diagnostic response-snippet capture is capped in bytes (on a
codepoint boundary), so a captured snippet always satisfies its
constraint under either mode. Your application owns the choice. See
Ash's
[backwards-compatibility config guide](https://hexdocs.pm/ash/backwards-compatibility-config.html#default_string_length_count)
for per-attribute overrides.

## 1.0.1 → 1.0.2

Two behavior corrections to know about (both security-posture fixes; no API change):

### 1. The alternate `:httpc` adapter refuses literal-IP HTTPS

`AshHooks.Http.Httpc` (NOT the default) now returns `{:error, :ip_literal_https_needs_bounded}`
for `https://<ip-literal>` destinations. It previously validated only the chain, which let
any chain-valid certificate authenticate the endpoint IP. The default adapter
(`AshHooks.Http.Bounded`) enforces the iPAddress-SAN floor and keeps working; if you swapped
to `:httpc` AND deliver to literal-IP HTTPS endpoints, switch those deliveries back (or drop
the `:http` override).

### 2. `use AshHooks.Worker` no longer drops `:http_opts`

`http_opts:` was accepted and silently ignored; it now threads to the adapter. A config that
passed it with a wrong shape could start behaving differently (correctly); see the `:cacerts`
seam in the README/CHANGELOG for the intended use (private-CA bundles: compile-time literals,
or `{m, f, a}` resolved per-perform for computed values).

## 0.2.0 through 0.2.2 → 1.0.0

1.0.0 defines the stable public API. There are **no public API removals or renames**
from 0.2.0 through 0.2.2; upgrading is a version bump plus three behavior corrections to know about:

### 1. Truncated chunked bodies now retry (they previously "succeeded")

`AshHooks.Http.Bounded` (the default adapter) returns `{:error, :truncated_body}` when a
chunked response ends early, before its response-body cap is reached, exactly as it
already did for Content-Length responses. At the cap it returns the captured bytes as
success and closes the connection without reading the rest. In
0.2.0 through 0.2.2 the chunked path returned a partial body as success, which could mark a delivery
`:succeeded` on partial bytes. If a receiver of yours streams chunked responses and
closes mid-body before the cap, deliveries now retry instead of silently truncating.

### 2. `AshHooks.Delivery.prune/2` returns `{:error, error}` instead of raising

Calling it on a delivery resource without `inserted_at` now returns the same error-tuple
contract as `AshHooks.Ingress.prune/2` (the `@spec` always promised this shape). If you
rescued the old `ArgumentError`, replace it with an `{:error, error}` match.

### 3. Literal-IP https endpoints actually work now

The literal-IP certificate check requires the IP in the certificate's IP subject
alternative name. In 0.2.0 through 0.2.2, it rejected **every** literal-IP HTTPS endpoint
fail-closed with `:cert_ip_mismatch`. It now verifies correctly: endpoints whose certs
carry the IP SAN deliver; certs without it still fail closed. No action needed unless
you had worked around the rejection.

### Install constraint

<!-- tested: upgrade-dependency-1-0 -->
```elixir
{:ash_hooks, "~> 1.0"}
```

### Semver from here

`~> 1.0` now means: breaking changes only in 2.0, deprecations run two minors minimum,
safety corrections ship as fixes even where the defective behavior was depended on
.
