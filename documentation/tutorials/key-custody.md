# Key custody and lifecycle

Use custody when signing and verification must happen without returning stored
secret bytes to ash_hooks. Your application supplies a custodian implementing
`AshHooks.Custody`, an Ash resource using `AshHooks.KeyRegistry`, and the endpoint
or inbound source resources that own the keys. The host owns storage, migrations,
policies, secure disclosure, and sweep scheduling for every tenant.

The [Livebook](../livebooks/get-started.livemd#custody-a-host-owned-key-store)
contains complete SQLite resources, a real cryptographic custodian, its conformance
tests, and delivery to a request-capture receiver. Start there to run this guide.
The [get-started tutorial](get-started.md) introduces dispatch and ingestion.

## Implement the custodian

An `AshHooks.Custody.Key` carries only `custodian`, `ref`, canonical `tenant`, and
`kind`. It is not a secret. The package chooses a globally unique `ahk_` UUIDv7
reference for each slot occupancy; never share references between owners or slots.

Implement all six callbacks. `store(ref, material, tenant, kind)` receives decoded
cryptographic material, not a `whsec_` or `whsk_` wire value. `sign/4` returns a raw
signature, `verify/5` checks a raw signature, `public_key/3` returns the raw Ed25519
public half, `fingerprint/3` returns the specified 16-byte digest, and `destroy/2`
erases material while retaining its permanent tombstone.

| Kind | Material accepted by custody | Operations and generation |
| --- | --- | --- |
| `{:standard_webhooks, :v1}` | 24 to 64 raw bytes | HMAC-SHA256 signing and verification; package generation uses 32 random bytes |
| `{:standard_webhooks, :v1a}` | Exactly a 32-byte Ed25519 seed | Signing, verification, and public disclosure; package generation uses 32 random bytes |
| `{:sender_hmac, digest}` | 1 to 16,384 decoded bytes | Verify only; digest is `:sha1`, `:sha256`, `:sha384`, or `:sha512`; never generated or admitted to an endpoint |
| `{:legacy_hmac, :sha256}` | At least one byte, with no upper bound | HMAC-SHA256 signing and verification; package generation uses 32 random bytes |

Every `expected_kind` argument is an assertion against the stored kind. Check it
before computing and return `{:error, :kind_mismatch}` on disagreement. Sender
HMAC signing returns `:not_signable`; non-Ed25519 public disclosure returns
`:no_public_half`. Check complete MAC lengths and compare in constant time;
truncation and corruption return `:invalid_signature`.

Store must be idempotent only for the exact reference, material, kind, and tenant.
Bind a reference globally and atomically to its first tenant, including a destroy
of an absent reference. Another store of a live reference returns `:ref_exists`.
A tombstone refuses every later store with `:ref_destroyed`. Reads under another
tenant return `:unknown_ref`, while wrong-tenant destroy returns `:tenant_mismatch`
and leaves the original key working. Store and destroy must be linearizable,
including delayed stores after destruction. Tombstones live as long as the store.
An outage returns `:unavailable`; do not turn an outage into an invalid signature.

Run `AshHooks.Custody.Conformance` with `custodian: YourCustodian` in an ExUnit
module. Its setup must provide a fresh real store per test and register cleanup
with `on_exit`. It checks bounds, kinds, real signatures, literal fingerprint
vectors, tenant isolation, idempotence, tombstones, and concurrent store/destroy
ordering. ExUnit is needed only in consumer tests. Passing the template does not
establish constant-time behavior of your backend.

## Declare owners and the registry

Use `extensions: [AshHooks.KeyRegistry]` on a host resource; configure its table
and repository and register it in your domain. The registry's only primary key
is `ref`, so do not add an `id` primary key. Owners and registry must share
transactional AshPostgres or AshSqlite storage, the write repository, and matching
attribute tenancy. SQLite repositories enable `write_transactions?/0`. Generate
and apply migrations for all injected attributes before using the resources.
[UPGRADING](../../UPGRADING.md#310--320) lists the columns and database types.

The registry injects `:read`, `:issue_key`, `:transition_key`, and `:prune_keys`
when absent. Host replacements must preserve their documented inputs and state
transitions. These are machine actions, not application APIs. Authorize callers
before exposing lifecycle helpers: package system operations use `authorize?: false`.
Do not manually issue references or drive registry transitions around an owner write.

On an endpoint, configure `custodian`, `key_registry`, and `key_lifecycle :on`.
Migrate `secret_kind` and `previous_secret_kind` as nullable `:term` binary columns
alongside the lifecycle timestamps. A nonnull kind marks the adjacent reference
as custody-owned. A null kind still selects a host byte resolver. Direct host
actions cannot set custody kinds. Without `secret_resolver`, create endpoints
through `create_with_key/3` and roll through issuance, never caller-chosen references.

## Issue, roll, recover, and retire endpoint keys

Create with exactly one of `generate: kind` or `material: wire_key`.
Standard slots generate v1 or v1a. Imports use the signing API's wire format:
`whsec_` for symmetric material or `whsk_` for an Ed25519 seed. Generation returns
`{:ok, endpoint, disclosure}`; import returns `{:ok, endpoint}`. A v1 disclosure
is the `whsec_` secret; v1a discloses only the `whpk_` public half. Deliver it
securely once. Never log it or persist it on the endpoint.

With `endpoint_resource`, `registry_resource`, and `tenant` bound to your application's
resources and tenant, this sequence runs creation, rotation, lost-disclosure
recovery, deadline removal, and destruction. The Livebook also sends signed requests
before and during the overlap and verifies their captured bytes.

<!-- tested: key-custody-endpoint-lifecycle -->
```elixir
now = DateTime.utc_now()

{:ok, endpoint, initial_disclosure} =
  AshHooks.Endpoint.create_with_key(
    endpoint_resource,
    %{url: "https://hooks.example.test/events"},
    tenant: tenant,
    generate: {:standard_webhooks, :v1},
    now: now
  )

{:ok, endpoint, _lost_disclosure} =
  AshHooks.Endpoint.roll_secret(endpoint,
    tenant: tenant,
    generate: {:standard_webhooks, :v1},
    overlap_seconds: 60,
    now: now
  )

{:ok, endpoint, replacement_disclosure} =
  AshHooks.Endpoint.reissue_secret(endpoint, tenant: tenant, now: now)

{:ok, endpoint} =
  AshHooks.Endpoint.schedule_previous_retirement(endpoint, now, tenant: tenant, now: now)

{:ok, 1} =
  AshHooks.Endpoint.expire_previous_secrets(endpoint_resource, tenant: tenant, now: now)

{:ok, %{destroyed: 2, destroy_failed: 0}} =
  AshHooks.KeyRegistry.sweep(registry_resource, tenant: tenant, now: now)
```

A roll moves the incumbent and its kind into the previous slot. Both sign before
the previous key's retirement instant. The deadline excludes the previous key
even if no sweep has run. First-use timestamps record only keys actually used,
fenced against concurrent replacements. Current and previous Standard Webhooks
keys may use different algorithms.

A second roll during an active overlap returns `:overlap_active`. An ended
window permits a roll before the sweep. An undated previous key keeps signing,
is skipped by the sweep, and returns `:previous_secret_undated` on a roll. Use
`schedule_previous_retirement/3` or `expire_previous_secret/2` to resolve it.
Scheduling is fenced on the previous reference; a concurrent change returns
`:previous_secret_changed`. A past deadline or absent previous reference is refused.

`default_overlap_seconds` defaults to 86,400. `max_overlap_seconds` is an optional
positive cap, at least the effective default. `overlap_seconds: 0` is a hard cut.
Negative or noninteger durations return `:invalid_overlap`; a roll or scheduled
deadline above the cap from the application clock returns
`{:overlap_exceeds_max, max}`. `:now` accepts that clock for lifecycle operations.

Reissue generates the same kind as the current custody key. It immediately
revokes the replaced current key, preserves the previous key and its deadline,
and creates no new overlap. It is for a committed generation whose disclosure
was lost, not ordinary rotation. Byte slots return `:byte_slot`. Endpoint v1,
v1a, and legacy kinds can be generated; sender HMAC kinds cannot.

Issuing helpers refuse enclosing transactions with `:inside_transaction`. They
commit an issue before calling custody outside transactions, then attach it and
persist ownership in the owner's transaction. Failed attempts retire their own
issues. `:key_issue_expired` means cleanup won before attachment; repeat with a
fresh issue. `:owner_mismatch` means the create action did not persist the issued
references in their intended slots; fix the action before retrying.

### Legacy slots

Enable `legacy_key_lifecycle :on` as well as `key_lifecycle :on` to track legacy
keys. Migrate its five nullable timestamps and two nullable kind columns. Pass
`slot: :legacy` to roll, reissue, schedule, and expire helpers; the default is
`slot: :standard`. Each operation leaves the other slot unchanged. For a byte-backed slot,
`new_secret_ref:` must differ from both its incumbent and previous reference;
reusing either returns `:same_reference`. Legacy issuance uses `generate: {:legacy_hmac, :sha256}` or exact raw `material:` bytes.
Its disclosure is the raw binary, not a wire-encoded replacement key. Empty legacy
slots install a current key without a previous key. Overlap rules and first-use
fences apply to both slots. With the legacy option off, legacy lifecycle columns
and actions are not injected and host byte references retain their existing behavior.

## Schedule disposal and handle failures

Run the owner lifecycle sweeps and `AshHooks.KeyRegistry.sweep/2` for every tenant.
The first removes expired previous slots and retires their references in the same
transaction. The registry commits retirement before calling `destroy/2` outside
transactions, using the canonical tenant recorded at issue. It also reconciles
deleted owners and displaced references, even after bulk deletion, cascade, or SQL.
The owner's `base_filter` applies to reconciliation; a hidden owner counts as gone.

Registry states move from `:issued` to `:attached`, then `:retired` and
`:destroyed`. `issue_timeout` defaults to 900 seconds; set it longer than your
custodian's store timeout. A crashed, unattached issue times out and is destroyed;
the permanent tombstone prevents a delayed store from reviving it. Sweeps refuse
enclosing transactions and process bounded batches.

Unavailable destruction retries with exponential backoff capped at one hour.
Other failures park only that reference in `:destroy_failed`. Alert on
`[:ash_hooks, :key_registry, :destroy_failed]`, measurement `%{count: 1}`, metadata
`registry`, `ref`, and fixed `reason`. Backend terms never enter telemetry or rows.
Inspect `pending/2`, repair the cause, then `rearm/3` with registry, reference,
and tenant. Its generation fence rejects delayed results from before rearming.
`prune/2` with `before: timestamp` removes only old destroyed audit rows, never
pending obligations or custody tombstones. Keep owner modules available until
their obligations have been destroyed and pruned.

## Display fingerprints and canonical tenants

Use `AshHooks.Signing.display_fingerprint/1` for `whsec_`, `whsk_`, or `whpk_`
values; use `AshHooks.Custody.display_fingerprint/1` for an opaque spec key.
Both return `{:ok, "SHA256:" <> text}` with the same domain-separated 16-byte
digest. An Ed25519 private seed and its public half share a fingerprint. This is
separate from telemetry's correlation fingerprint. Sender and legacy kinds have
no display fingerprint. Fingerprints of weak secrets permit offline guessing;
use securely generated material.

Derive custody identity with `canonical_tenant/3`, not `to_string/1`. It applies
`Ash.ToTenant`, the resource's parser, then constrained Ash casting. UUIDs normalize
case, integers become decimal text, strings stay exact UTF-8, and ci_strings
normalize case. Non-multitenant resources use `nil`. Invalid values return
`:invalid_tenant`; unsupported types return `:unsupported_tenant_type`.
`tenant_type_supported?/2` checks coverage without calling custody.
For other attribute types, declare `custody_tenant_key {module, function, args}`;
the callback must give equal UTF-8 text whenever the database treats values as equal.
Recover stored row tenants with `AshHooks.Tenancy.from_row/1`, which uses
`tenant_from_attribute`, before passing tenant options or canonicalizing.

## Migrate byte references and enforce custody

Keep the endpoint's `secret_resolver {module, function}` while adding custody
and the registry. Give every occupied previous key a deadline before adoption;
`adopt_keys/2` refuses undated previous references. With legacy lifecycle disabled,
retire an undated legacy previous byte reference through the host's existing
management path, or enable legacy lifecycle and schedule it before adoption.
Run `adopt_keys(endpoint, tenant: tenant)` on every row. It converts occupied
standard slots together without changing timestamps, skips existing custody
slots, and includes legacy slots when their lifecycle is enabled. Otherwise
legacy slots stay byte references. Original host references never enter the
registry. Failed attempts retire their new issues; repeats are resumable.
`tenant_aware_secrets: true` passes the tenant as the resolver's second argument.

Mixed slots keep working during the transition: kind markers select custody,
null markers select bytes. Retain the resolver until every occupied slot is
adopted. Then remove it and delete the original material from the host store
under your application's retention policy. The
[upgrade procedure](../../UPGRADING.md#310--320) covers the ordered migration.

Set the application configuration `:ash_hooks, key_material: :custody_only`
before compiling resources and providers to refuse endpoint and worker byte
resolvers, inbound `secret` and `previous_secret` sources, and provider
`webhook_signing_secret/1` and `/2` callbacks. The default remains compatible
with bytes. Direct byte signing and verification APIs remain available.

## Own inbound source keys

An `AshHooks.InboundSource` resource holds source identity, a provider alias,
keys, and pause state. Declare `ledger`, `providers`, `custodian`, and
`key_registry`. `source_attribute` defaults to `:source`; local `scope` tuples
must match the ledger's nonnullable `scope_identity` attributes, including types
and constraints. Source, ledger, and registry must have compatible tenancy and
transactional storage. `custody_tenant_key`, `max_overlap_seconds`, and
`default_overlap_seconds` follow the same contracts as endpoints.

Register the resource in the domain, migrate its injected fields, enable ledger
`record_provider_alias :on` and its nullable `provider_alias` column, and declare
`source_record YourSource` instead of declaration-level key callbacks.
Providers come from the code-defined alias allowlist, never request modules.

| Operation | When to use it |
| --- | --- |
| `create_source/3` | Import sender-issued `material:` with `kind:`, generate symmetric standard v1, or pin `public_key:` with an asymmetric `kind:` |
| `roll_secret/2` | Import or generate a replacement with a dated overlap; only standard v1 can be generated for a source |
| `reissue_secret/2` | Recover a lost standard v1 disclosure; immediately replaces current, preserving previous; sender kinds return `:kind_not_allowed` |
| `schedule_previous_retirement/3` | Set the previous key's deadline within the configured cap |
| `expire_previous_secret/2`, `expire_previous_secrets/2` | Remove previous keys now or sweep those past their deadline, retiring custody references for disposal |
| `register_public_key/3` | Replace a pinned sender public key outside custody with a required asymmetric `kind:` |
| `pause/2`, `unpause/2` | Refuse or resume new requests; already authenticated receipts remain recoverable |

Generation returns `{:ok, source, disclosure}`; imports and public-key creation
return `{:ok, source}`. Creation may import `previous:` with
`previous_retires_at:` and optional `previous_kind:`. Never install an undated
previous key. Source imports take decoded key bytes. Decode the sender's configured encoding
or a spec key's wire encoding before passing `material:`; custody stores those
bytes and asserts their declared kind.

Public keys never enter custody. `AshHooks.Custody.PublicKey.new/2` validates
material against its pinned algorithm, digest, RSA padding, and ECDSA curve before
writes. Kinds include `{:standard_webhooks, :v1a}` for `whpk_`, `:ed25519`, the
six RSA PKCS1/PSS digest variants, and ECDSA P256/SHA256 and P384/SHA384.
Providers receive the typed struct; HMAC refuses it as `KeyKindMismatch`.
The sender keeps its private key. Public-key replacement has no automatic overlap.

### Resolve once per request

Call `AshHooks.Ingress.resolve_source(ledger, name, tenant: tenant, scope: scope)`.
It casts and constrains every ledger scope field before reading a source under
its tenant. Missing, nil, or invalid scope is `MalformedPayload`, even without
`source_record`. The `AshHooks.Inbound.ResolvedSource` contains the selected
provider and alias, cast scope, `paused?`, current key, admitted dated previous
key, and a separate pinned public key. Pass it in the `:resolved_source` ingest
context together with that request's tenant and scope to reuse it. Resolve afresh
for each request; it is not a configuration cache. The
[Livebook source section](../livebooks/get-started.livemd#inbound-source-records)
executes the complete path.

`UnknownSource` means an absent source row (Plug answers 404). `UnknownKey` and
`KeyKindMismatch` are configuration failures (500); `KeyUnavailable` and contained
callback faults are outages (503). Paused requests also get 503 by default.
Outages and pauses do not create failed-verification rejection rows. Invalid
signatures remain authentication failures. Custody and byte keys may coexist in
HMAC rotation lists; a key outage is not reduced to a MAC mismatch. A displaced
unknown reference triggers at most one owner reread, retrying only if that owner
no longer admits it.

### Preserve the authenticating provider

A receipt records the provider alias that authenticated it. Claims and recovery
use that durable alias and payload, even after the source changes, pauses, or is
deleted. When moving an existing declaration to `source_record`, enable alias
recording, switch the declaration, then run `adopt_provider_alias/4` per source
and tenant with the old module as `expected_provider:`. Use a positive bounded
`limit:` and repeat until `remaining` is zero; it includes live old claims.
Each alias stamp and claim commits before handling. Terminal nil-alias rows
stay unchanged. Incorrect limits, declarations, or aliases return `:invalid_limit`,
`:source_mismatch`, or `:provider_mismatch`. Run adoption outside an enclosing
transaction; see [UPGRADING](../../UPGRADING.md) for the full cutover.

Optional `parse_event_type/2`, `event_identity/2`, and `handle_event/3` receive
`AshHooks.Provider.DeliveryContext`. Tenant, source, cast scope, and provider alias
are available throughout; persisted delivery and external event IDs appear only
at handling. Recovery rebuilds the context from the receipt. Headers are absent
because recovery cannot reconstruct them. Existing callback arities still work.

## Apply JSON policy, pause subscriptions, and bind database phases

The [verification guide](verify-any-sender.md#request-scoped-json-policy) teaches
ledger `json_decoder`, provider `decode_payload/2`, direct scheme decoding, JWS
`json_decoder:`, and `AshHooks.Provider.Conformance`. These keep the application's
JSON policy consistent through verification and delivery.

Outbound subscription `pausable :on` adds a required boolean `paused`, default
`false`. The default `:off` adds no column. Migrate existing rows with that default and expose an authorized update
action accepting it. Updating to `true` suppresses new delivery rows; existing
pending or in-flight deliveries continue. Updating to `false` resumes fanout.
It is independent of inbound source pause and endpoint disable. The Livebook
executes pause, suppression, existing delivery completion, and resume.

Package database work uses bounded tenant transactions and reads the write
repository inside each phase. PostgreSQL row security binds tenant settings in
`on_transaction_begin/1`; schedule all sweeps per tenant. The SQLite Livebook
cannot exercise PostgreSQL policies. Follow the
[row-security guide](row-security.md) for table and job policies. Delivery and
`test_send/2` refuse enclosing transactions; enqueue after commit. Monitored
delivery and finalization children inherit the configured caller tracer context.
