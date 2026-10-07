# Upgrading

## 1.x → 2.0.1

2.0 changes the durable delivery schema and HubSpot's default event identity.
Drain old jobs and migrate before activating the new runtime. Mixed 1.x/2.x
workers against one ledger are unsupported.

### Ordered deployment

1. Quiesce outbound producers, ingress, workers, inbound reapers, and recovery
   schedulers. Drain in-flight 1.x Oban jobs. Record pending rows, retry times,
   tenant partitions, declaration ownership, and the current queue binding.
2. Upgrade to `{:ash_hooks, "~> 2.0"}` with Ash >= 3.34.3 and < 4.0. Generate
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
5. If a HubSpot declaration uses the former digest default, adopt retained
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

### HubSpot identity adoption

The new HubSpot identity hashes a canonical whole batch. It ignores only outer
`attemptNumber` values, sorts object keys and outer events, preserves batch
multiplicity, and preserves order inside nested lists. Other changed event
content remains a distinct event. The precedence is explicit declaration
`event_id` extractor → provider `event_identity/1` → raw-body digest when the
provider does not implement the callback. A callback error never becomes a digest.

Plan each provider/scope/tenant partition and retain its audit before applying:

```elixir
opts = [tenant: tenant, scope: %{account_id: account_id}]
{:ok, plan} = AshHooks.Ingress.plan_legacy_identity_adoption(MyApp.InboundLedger, :hubspot, opts)
# Review plan.audit; resolve every item in plan.unresolved and plan.conflicts.
{:ok, applied} =
  AshHooks.Ingress.adopt_legacy_identity(MyApp.InboundLedger, :hubspot, Keyword.put(opts, :quiesced?, true))
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

A domain provider wrapping the built-in HubSpot provider must delegate
`event_identity/1` along with its signature/type callbacks:

```elixir
defdelegate event_identity(payload), to: AshHooks.Provider.HubSpotV3
```

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

## 1.2.1 → 1.3.x

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
   extra values — the fail-closed direction.

New options, all opt-in: rename the exact-bytes column
(`payload_attribute`), omit the retention destroy action
(`prune_action :none`), map the durable enable/disable onto your own
switch (`endpoint do status_attribute ... end`), and atom-typed
subscription registers now match. The README's "Fitting the extensions
to your domain" section shows each.

## 1.1.1 → 1.2.x

### Multi-tenancy is available and opt-in (ADR-0011)

Nothing changes unless you declare multitenancy on the four resources
(Subscription, Endpoint, both ledgers). If you do, read the adoption
checklist (`documentation/tutorials/tenancy-adoption-checklist.md`) —
the ordered transition for populated tables is **backfill the tenant
attribute → regenerate identity indexes → enable multitenant
dispatch**. A NULL-tenant legacy row forms a shadow partition: new
tenant-bearing upserts create parallel rows and allow repeated processing of
the same logical event.

Two obligations for multi-tenant adopters:

1. **Drain in-flight 1.1.x Oban jobs before serving multitenant
   dispatch.** Pre-tenancy job args carry no tenant and fail closed
   (`{:error, :tenant_required}`) against multitenant resources —
   correct, but noisy. Drain first.
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

## 1.0.4 → 1.1.x

### Elixir 1.20+ required (previously 1.17+)

The supported Elixir window is now `~> 1.20`. Applications resolving
ash_hooks on Elixir 1.17–1.19 get a hard resolver error at deps
loadpaths instead of a compile. Per ADR-0010 rule 4 a supported-floor
bump ships as a MINOR release — so a `~> 1.0` pin will happily resolve
1.1.0 and then fail resolution on old Elixirs. If you cannot move to
Elixir 1.20 yet, pin the floor release instead:

```elixir
{:ash_hooks, "~> 1.0.4"}
```

## 1.0.3 → 1.0.4

Behavior corrections (all also under "Fixed" in the CHANGELOG; no API change):

### 1. Event ids and types are bounded by BYTES, not characters

`AshHooks.Event.new/1` and dispatch previously accepted ids and types up to
255 *characters* (graphemes). Long multi-byte values could pass that check
and then fail the delivery write — under Ash 3.33's `:codepoints` counting,
every endpoint's dispatch errored on an event the library had validated.
Ids and types are now rejected above 255 **bytes** at `Event.new/1`, with a
clear error. If you build event types from multi-byte text, values between
255 characters and 255 bytes now fail fast at construction — which, under
`:codepoints`, previously failed (less clearly) at dispatch.

### 2. Captured snippets and error fields are byte-capped

The 2048-character snippet cap and 255-character error-summary caps counted
graphemes; they now cap **bytes** (on a codepoint boundary). Captured
diagnostic snippets of multi-byte content come out slightly shorter, and a
hostile response body built from combining characters can no longer crash
the post-send ledger write — the same applies to thrown/exit error
classifications.

### 3. Handler failures with invalid-UTF-8 binaries still record

A handler returning `{:error, :retry | :permanent, term}` where `term` is
invalid UTF-8 previously made the failure-recording write itself fail, so
the delivery stayed re-drivable with no record. It now records `[binary]`
as the error class.

## Ash 3.33+: the required `default_string_length_count` config

Ash 3.33 made `config :ash, :default_string_length_count` REQUIRED for
every application that compiles Ash resources — resource compilation
fails until it is set. This is an Ash-level requirement (part of the fix
for GHSA-cwjv-574p-59f6, where grapheme-based counting let values built
from unbounded combining characters through `max_length` limits), not an
ash_hooks one; ash_hooks writes no `:ash` configuration for you. Set it
in your application's `config/config.exs`:

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
graphemes — the exact tradeoff Ash documents for your own attributes.
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
for `https://<ip-literal>` destinations. It previously validated only the chain — which let
any chain-valid certificate authenticate the endpoint IP. The default adapter
(`AshHooks.Http.Bounded`) enforces the iPAddress-SAN floor and keeps working; if you swapped
to `:httpc` AND deliver to literal-IP HTTPS endpoints, switch those deliveries back (or drop
the `:http` override).

### 2. `use AshHooks.Worker` no longer drops `:http_opts`

`http_opts:` was accepted and silently ignored; it now threads to the adapter. A config that
passed it with a wrong shape could start behaving differently (correctly) — see the `:cacerts`
seam in the README/CHANGELOG for the intended use (private-CA bundles: compile-time literals,
or `{m, f, a}` resolved per-perform for computed values).

## 0.2.x → 1.0.0

1.0.0 is the semver freeze (ADR-0010). There are **no public API removals or renames**
from 0.2.x — upgrading is a version bump plus three behavior corrections to know about:

### 1. Truncated chunked bodies now retry (they previously "succeeded")

`AshHooks.Http.Bounded` (the default adapter) returns `{:error, :truncated_body}` when a
chunked response ends early — exactly as it already did for Content-Length responses. In
0.2.x the chunked path returned a partial body as success, which could mark a delivery
`:succeeded` on partial bytes. If a receiver of yours streams chunked responses and
closes mid-body, deliveries now retry instead of silently truncating.

### 2. `AshHooks.Delivery.prune/2` returns `{:error, error}` instead of raising

Calling it on a delivery resource without `inserted_at` now returns the same error-tuple
contract as `AshHooks.Ingress.prune/2` (the `@spec` always promised this shape). If you
rescued the old `ArgumentError`, replace it with an `{:error, error}` match.

### 3. Literal-IP https endpoints actually work now

The literal-IP certificate check (IP must appear in the certificate's iPAddress SAN,
ADR-0009) was dead-on-arrival in 0.2.x — it rejected **every** literal-IP https endpoint
fail-closed with `:cert_ip_mismatch`. It now verifies correctly: endpoints whose certs
carry the IP SAN deliver; certs without it still fail closed. No action needed unless
you had worked around the rejection.

### Install constraint

```elixir
{:ash_hooks, "~> 1.0"}
```

### Semver from here

`~> 1.0` now means: breaking changes only in 2.0, deprecations run two minors minimum,
safety corrections ship as fixes even where the defective behavior was depended on
(ADR-0010).
