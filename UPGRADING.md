# Upgrading

## Unreleased

### Dynamic repositories and Oban

If your host selects physical databases with Ecto dynamic repositories, add
`binding: MyApp.HooksBinding` to the generated worker and configure its
`oban/1` callback to return the matching Oban instance. New jobs carry the
binding name in `args["ash_hooks_binding"]`. Earlier jobs still use the
repository selection of the process executing them. Drain those jobs in their
existing context before moving queues to different physical databases. Deploy
the binding implementation to the processes that run jobs before enabling it
in the processes that enqueue them.

Select the database in the calling process before publishing, sending returned
notifications, or running a sweep. Keep binding names valid while jobs
reference them. This change requires no schema migration. See the
[physical database guide](documentation/tutorials/tenancy-adoption-checklist.md#physical-database-bindings).

### Event-log replay

Missing deliveries require an enabled endpoint and an active subscription
matching the event type and filters. Unmatched events count as `skipped`.
Dry-run `count` is the number of eligible new deliveries in the selected batch.

To replay through a filtering subscription or to a pinned endpoint, add the
nullable `:replay_context` map column to the event log's table and enable
`replay_context(:on)` in the resource's `outbound_event` block. Use Ash migration
generation or add `add :replay_context, :map` in the host's Ecto migration.
No schema change is needed with capture off.

Rows written before capture have a null value. Leave it null. Replaying those
rows through a filtering subscription returns `:replay_metadata_unavailable`. A
missing delivery for a pinned endpoint returns `:replay_payload_unavailable`
when the log cannot establish the payload version or rebuild the variant.
Unpinned endpoints with unfiltered subscriptions can still replay older rows.
Existing terminal deliveries use the bytes already stored in their delivery
rows.

<a id="upgrade-3-7"></a>

## 3.6.0 → 3.7.0

Before upgrading ash_hooks, update your Ash requirement to allow 3.38.1 or later
within the 3.x series, and update your lockfile if it holds an older Ash release.

<!-- not-run: This changes an adopter's project dependencies and lockfile. -->
```sh
mix deps.update ash
```

<a id="upgrade-3-6"></a>

## 3.5.0 → 3.6.0

No changes are required. 3.6.0 adds `AshHooks.Egress` and the optional
`AshHooks.Egress.ReqAdapter` (Req `~> 0.7.5`); webhook delivery results are
unchanged. See the [pinned egress guide](documentation/tutorials/pinned-egress.md).

<a id="upgrade-3-5"></a>

## 3.4.0 → 3.5.0

### Observe cancelled worker jobs

Jobs that used to complete without work now end `cancelled`: fanout returns
`{:cancel, :publication_missing}` for no visible row and
`{:cancel, :publication_failed}` for a parked publication. Unknown sources and
invalid fanout arguments cancel with `:unknown_source` and `:invalid_event`.
Delivery returns `{:cancel, :delivery_missing}` for no visible row and
`{:cancel, :invalid_delivery_identity}` for invalid or absent identity,
including malformed complete primary keys. Hosts alarming on Oban `cancelled`
jobs will now see these cases. Oban does not retry cancelled jobs.

Outbox claim telemetry gains `:missing`, `:done`, `:failed`, and `:error`
outcomes. Every fanout reaching the read emits one event for its read or claim
outcome. Acquired claims report `:claimed` when the claim write succeeds,
before work starts; a run that loses its fenced lease also emits `:stale`.
The new `[:ash_hooks, :delivery, :missing]` event carries the job's `endpoint_id`,
`event_uuid`, and/or complete `delivery_pk`, including any tenant key component.
This event and every outbox event include `tenant`, the operation's tenant
identifier or `nil` when absent, so hosts can alarm per tenant. Payloads and
metadata contents are omitted.

A hidden row looks absent. Alarm on cancellations and missing telemetry, and
bind the tenant in the repository's transaction-begin callback for every
tenant-bearing phase. See the [row-security guide](documentation/tutorials/row-security.md).
Fanout `:busy`, `:stale`, and persisted pending retries still complete the job
without re-enqueueing it. The required per-tenant `AshHooks.fanout_pending/3`
sweep finishes that work; without it, publications stay pending. Delivery
retries keep Oban snoozes or retries of the same job, with the host-scheduled
`AshHooks.reconcile_pending/3` path recovering stranded deliveries.

Event-log replay now returns `%{created, re_sent, skipped, errors}`. Delivery
read, replay create, and terminal resend errors no longer count as skipped;
their error terms are returned in `errors`. Inspect that list even when the
call returns `{:ok, summary}`. Only live, nonterminal rows left alone count as
skipped. A delivery read error never causes a replay insert. Dry-run results
remain `%{count: n}`. No schema migration is required.

<a id="upgrade-3-4"></a>

## 3.3.0 → 3.4.0

Transactional publication is opt-in. Existing hosts need no migration unless
adopting `AshHooks.OutboundOutbox`. Immediate dispatch still persists deliveries
and enqueues synchronously. Dispatch applies subscription filters in the
primary read, using SQL on PostgreSQL and SQLite, and retains the Elixir guard.
Malformed filter containers never match. This corrects the former
`__invalid__` sentinel case for every host.

The non-recursive key-set metadata-filter arm (5C) ships under the fallback
rule. The [final probe run](https://github.com/baselabs/ash_hooks/actions/runs/44224659651)
found zero false negatives across 152,379,216 pairs and no JIT in 810 plans
per PostgreSQL version. Its p95 exceeded the allowance in 90, 86 and 85 of
810 cells on PostgreSQL 16, 17 and 18, respectively. Its worst p95 ratios to
the type-and-pause baseline B were 3.37, 3.22 and 2.28, or up to 3.4 times B's
p95. The recursive walk triggered JIT and measured a worst p95 of at least
174 times B, so the key-set arm was selected.

### Check host declarations of injected attributes

Every resource extension now verifies host overrides against its native field
contract. A refusal names the resource, attribute, declared type, nullability
and constraints, and accepted shapes. This catches configurations that cannot
store package action inputs or that break matching and state transitions.
Restore the injected type or a supported variant and migrate incompatible
stored values before changing the column type. The following table lists
all injected fields; optional groups apply only when their DSL option is on.
`required` means `allow_nil?: false`; `nullable` means `allow_nil?: true`
because package actions write or clear nil. Host-owned `event_types`, `event_filters` and subscription `signing_mode` accept either
nullability. Endpoint `status`, `response_capture` and
`response_capture_retention_seconds` also accept either nullability: nil status
is disabled, nil capture is off, and retention is a host pruning setting. Ordinary defaults, constraints and writable settings keep
their existing contracts.

| Resource | Type and fields | Nullability |
| --- | --- | --- |
| Subscription | Boolean: `paused` under `pausable :on`; UUID reference: `endpoint_id` | required |
| Subscription on every data layer | string or atom array: `event_types`, including element NewTypes | either; nil matches nothing |
| Subscription on PostgreSQL, ETS and Simple | term array: `event_types`, including Term element NewTypes | either; nil matches nothing |
| Subscription on SQLite | Term arrays are refused: Term binaries cannot be carried by the adapter's JSON array encoding | use string or atom arrays |
| Subscription | map: `event_filters` under `filter_attributes` | either |
| Subscription | atom: `signing_mode` | either |
| Endpoint | `AshHooks.Endpoint.Url` or string (send-time validation only): `url`; atom: `status`; `AshHooks.Endpoint.SecretRef` or string: `secret_ref` | required; optional native signing makes `secret_ref` nullable |
| Endpoint | SecretRef or string: `previous_secret_ref`, `legacy_secret_ref`, `legacy_previous_secret_ref` | nullable |
| Endpoint capture | Boolean: `response_capture`; integer: `response_capture_max_bytes`, `response_capture_retention_seconds`; string array: `response_header_allowlist` | required |
| Endpoint lifecycle | UTC microsecond datetime: `secret_created_at`, `secret_first_used_at`, `secret_retired_at`, `previous_secret_created_at`, `previous_secret_first_used_at`, `previous_secret_retired_at`, `legacy_secret_created_at`, `legacy_secret_first_used_at`, `legacy_previous_secret_created_at`, `legacy_previous_secret_first_used_at`, `legacy_previous_secret_retired_at` | nullable |
| Endpoint custody | term: `secret_kind`, `previous_secret_kind`, `legacy_secret_kind`, `legacy_previous_secret_kind` | nullable |
| Endpoint pinning and warning | integer: `pinned_payload_version`; UTC microsecond datetime: `disable_warned_at` | nullable |
| Outbound delivery | string: `event_uuid`, `event_type`, `dispatch_source`, `dispatch_route`; binary: `payload` or the configured `payload_attribute`; UUID reference: `endpoint_id`; atom: `status`; integer: `attempts` | required |
| Outbound delivery | UUID: `subscription_id`, `attempt_token`, `enqueue_token`; atom: `signing_mode`; UTC microsecond datetime: `send_lease_expires_at`, `enqueue_lease_expires_at`, `next_attempt_at`; map: `endpoint_snapshot`; integer: `response_status`; string: `response_snippet`, `last_error` | nullable |
| Outbound delivery resend and test | integer: `resend_baseline`, `resend_count`; Boolean: `test` | required |
| Outbound delivery resend | string: `last_resend_by`; UTC microsecond datetime: `last_resend_at` | nullable |
| Outbound attempt | map: `delivery_pk`; UUID: `endpoint_id`; string: `event_uuid`, `event_type`; integer: `attempt`; atom: `outcome`; Boolean: `test`; UTC microsecond datetime: `attempted_at` | required |
| Outbound attempt | string: `reason`, `response_snippet`, `signing_key_ref`; integer: `response_status`, `latency_ms`; map: `response_headers`; string array: `signing_key_refs` when provenance is on | nullable |
| Outbound event | string: `event_uuid`, `event_type`; binary: `payload` | required |
| Outbound event | integer: `version` | nullable |
| Inbound delivery | atom: `provider`, `status`; string: `external_event_id`, `payload_digest`; `AshHooks.InboundDelivery.Payload`: `payload`; integer: `fencing_token`, `attempts`, and optional `duplicates` | required |
| Inbound delivery | string: `external_event_type`, `error_class`; UTC microsecond datetime: `lease_expires_at`; optional atom: `provider_alias`; optional map: `verified_facts` | nullable |
| Inbound source | atom: configured `source_attribute`, `provider`; each declared scope type; Boolean: `paused` | required |
| Inbound source | SecretRef or string: `secret_ref`, `previous_secret_ref`; term: `secret_kind`, `previous_secret_kind`, `public_key`, `public_key_kind`; UTC microsecond datetime: `secret_created_at`, `secret_first_used_at`, `previous_secret_created_at`, `previous_secret_first_used_at`, `previous_secret_retired_at` | nullable |
| Key registry | string: `ref`; term: `kind`; atom: `owner_resource`, `state`; integer: `attempts`, `destroy_generation`; UTC microsecond datetime: `issued_at`, `inserted_at`, `updated_at` | required |
| Key registry | map: `owner_key`; string: `custody_tenant`, `last_error`; UTC microsecond datetime: `destroy_after`, `next_attempt_at` | nullable |
| Outbox | UUID: `id`, `acceptance_token`; string: `event_uuid`, `event_type`, `dispatch_source`, `dispatch_route`; integer: `version`, `format_version`, `attempts`; binary: `payload`; unmodified map: `metadata`; atom: `state`; UTC microsecond datetime: `next_attempt_at`, `inserted_at`, `updated_at` | required |
| Outbox | UUID: `claim_token`; string: `last_error`; UTC microsecond datetime: `lease_expires_at`, `completed_at`, `failed_at` | nullable |

The endpoint table shows generated nullability; the three nil-safe fields
listed above also accept nullable host declarations. Native
`Ash.Type.NewType` subtypes of the listed scalar types are accepted; event
arrays may use String, Atom or Term element NewTypes. Outbox metadata is the
exception; its codec must remain unmodified. Event string, atom and term
arrays can carry every declared event name on their supported data layers.
SQLite cannot encode Term arrays: `Ash.Type.Term` uses
`:erlang.term_to_binary`, while ecto_sqlite3 encodes arrays as JSON. A host
with this declaration must change it to `{:array, :string}` or
`{:array, :atom}` and migrate any imported column values to JSON string
arrays. An ordinary Ash create cannot have persisted native Term arrays on
SQLite. PostgreSQL, ETS and Simple keep Term arrays supported.
Boolean, integer and map element arrays, and scalar containers, cannot carry
those names and are refused; migrate their contents and column storage to a
supported array type before updating the declaration. Event atom arrays may
have a finite `one_of` constraint or be open. Open arrays and unrecognized
physical storage use conservative query selection and the Elixir guard.
UUID reference fields retain their UUID-storage compatibility check. The
default primary key is added only when a host has no primary key; existing
custom, composite and UUIDv7 primary keys retain their documented rules.
A mapped endpoint `status_attribute` remains a host-owned switch of any type.
A host `:string` or String NewType URL loses the injected URL type's
registration-time SSRF validation. Destinations are then validated only at
send time through the ordinary delivery guard, including retries, resends,
test sends and delivery after fanout. Keep the default destination policy
and transport validation unless the host intentionally owns that policy.
Inbound source identity and provider constraints must also match their native
specification. The outbox separately verifies the physical metadata codec and
PostgreSQL `json` migration type.

For every newly refused nullable required field, backfill existing nulls to
valid application values, then add `NOT NULL` and update the host declaration.
For a newly refused non-null field that the package clears, drop `NOT NULL`
and set `allow_nil?: true`; no backfill is needed. For an unsupported type,
convert existing values into the listed native domain, migrate the column and
restore the native declaration. Do not cast arbitrary identifiers into UUIDs;
retain their identity through an application migration or repair the reference.

For an existing nullable subscription `paused` column, the migration is
backfill first, then alter. This PostgreSQL example assumes the host's table
is named `subscriptions`; substitute the resource's actual table and source
column names. SQLite migrations perform the same backfill and rebuild the
table with `paused BOOLEAN NOT NULL DEFAULT FALSE` through AshSqlite's
migration generator. Set `allow_nil?: false, default: false` in the resource.

<!-- not-run: PostgreSQL migration template; substitute the host table and source column names. -->
```sql
UPDATE subscriptions SET paused = FALSE WHERE paused IS NULL;
ALTER TABLE subscriptions ALTER COLUMN paused SET DEFAULT FALSE;
ALTER TABLE subscriptions ALTER COLUMN paused SET NOT NULL;
```

A nullable `event_filters` column needs no migration. Null filters match.
A nullable `event_types` column also needs no migration. Nil event arrays
match nothing in the query and the final guard, on every data layer.

### Add and migrate the outbox

Define a separate resource using `AshHooks.OutboundOutbox`, a primary read
and the same attribute tenancy as subscriptions, endpoints and deliveries.
Declare the outbox's allowed `{resource, outbound_name}` pairs, named delivery
routes, and required `deduplication_horizon_seconds`. Generate the migration
with your data layer's migration generator and inspect it before applying it.
The `unique_publication` index must cover `(tenant_attribute, event_uuid)`;
there must be no global identity or partial identity predicate. Single-tenant
resources use `event_uuid` alone. Keep the ordinary primary-key index too.

The migration adds binary payload bytes, JSON metadata, version and format
version, declaration and delivery-route identifiers, acceptance and claim
UUIDs, state, attempts, lease, due time, bounded error and completion/failure
and insertion/update timestamps. It also declares tenant-leading partial
indexes on `next_attempt_at` where state is `pending`, and `failed_at` where
state is `failed`. Inspect both indexes in the generated migration. Do not
reuse the optional event-log table: its best-effort recording,
pruning and endpoint-targeted replay retain their existing behavior.

The PostgreSQL outbox `metadata` column uses native `json`, preserving integer
and float kinds, including scientific notation. Do not change that column to
`jsonb`, which normalizes numeric kinds. Subscription filters continue to use
`jsonb`.

Grant INSERT **and UPDATE** on the outbox to the producer role. Even a duplicate
executes `ON CONFLICT DO UPDATE` on the conflict keys to return the existing
row in one statement. Forced row security needs both INSERT and UPDATE
policies, including their checks, plus SELECT visibility of the returned row.
Give the fanout and sweep roles reads and the state-transition UPDATE grants.
Scope all policies and package phases to the tenant. Pruning needs DELETE;
it must not grant deletion of unfinished work through a host action.

Publish is atomic with host work only when it shares the same connection,
transactional data layer, write repository module and dynamic repository
instance. SQLite write repositories must enable `write_transactions?/0`.
The Ash change checks against its action resource. Direct callers supply
`:caller_resource` and, when selecting a dynamic instance, `:dynamic_repo`.
A successful acceptance inside a transaction is conditional on its commit.
Host hooks, notifiers and database triggers are outside the one-statement
package count. Outbox metadata has a JSON-only domain, described by
`AshHooks.publish/4`; immediate dispatch's wider metadata domain is unchanged.

### Configure both routes and both worker roles

A delivery route queues one delivery; an outbox trigger queues one fanout.
Declare them separately. For example, configure `delivery_routes` with
`default: {MyApp.Worker, :enqueue}` and `polling: nil`, configure `trigger`
with `{MyApp.Worker, :enqueue_fanout}`, and pass `outbox: MyApp.Publication`
to `use AshHooks.Worker`. The trigger callback receives the publication and
tenant. Route names are stored as opaque identifiers and resolved only through
host configuration. Renaming or removing a pending route is a transient
failure that eventually parks the publication at its attempt cap.

Keep the two Oban roles from ADR 0022: tenant-bound insertion uses the ledger
repository and PostgreSQL transactional notifier; the engine role must be
able to fetch runnable jobs across tenants. The engine establishes a fresh
tenant binding for each package phase. A fanout job carries `kind: "fanout"`,
outbox identity, event ID and tenant. Existing delivery jobs keep their meaning.
Oban remains optional. Without a trigger or Oban, polling and per-tenant
sweeps are the documented operating mode.

### Schedule recovery and retain identities

Schedule `AshHooks.fanout_pending(outbox, batch_size, tenant: tenant)` for each
tenant. The package does not discover tenants. The trigger is a latency hint;
the sweep is required even when the trigger is configured. Each candidate is
isolated. Inspect returned errors and failed rows rather than treating an
unreadable candidate set as zero work. Claim leases fence completion, and the
monitored runner is killed before lease expiry. Attempts use capped exponential
backoff; the default attempt cap spans more than 24 hours and its 240-second
backoff ceiling is below delivery reconciliation's default 300-second cutoff.

The deduplication horizon is the minimum retention of completed publications.
`AshHooks.OutboundOutbox.prune/2` and its injected prune action delete only done
rows older than that horizon. Pending, leased and failed rows survive. Once a
completed identity is pruned, the same event ID is a new publication. Delivery
retention has its own identity horizon (ADR 0026); coordinate both policies.

Inspect pending or failed rows with `AshHooks.OutboundOutbox.list/2`, selecting
`:state` and `:tenant`. Repair the classified cause, restore a missing route
or payload builder, then call `AshHooks.rearm/3`. Rearming only a failed row
resets its attempts and clears its failure timestamp. Unsupported stored
formats and invalid stored content park immediately; configuration failures
retry until the cap. Result telemetry follows successful fenced transitions.

### Versions, notifications and rollback

While publications remain pending, declare a builder for every version an
endpoint may pin, including the newly deployed version. Unpinned endpoints
and pins equal to the stored payload version receive the stored bytes.
Other pins run a declared builder; the deployed declaration version never
relabels older bytes. Every retry observes the current subscriptions,
pause flags, endpoints and builders, keeping earlier delivery rows.

In a raw `Repo.transaction`, the package's notifier checks physical commit
and gives no hint. Let the per-tenant sweep find the committed row, or call
`fanout/3` after commit. Never call fanout inside that transaction. Host
notifiers and host `after_action` notifications on the outbox resource follow
Ash's ordinary rules, including `missed_notifications` warnings and errors.

With `return_notifications?: true`, `publish/4` returns
`{:ok, disposition, notifications}`. Send all returned notifications with
`Ash.Notifier.notify/1` after commit to deliver the hint and host notifications.
Returned notifications the caller never sends, bulk notification suppression,
and writes outside the publish action rely on the sweep. Ash-managed
transactions delay the hint until physical commit; a trigger exception, exit
or throw never reaches the publishing caller. `AshHooks.Changes.Publish`
returns its notifications through the native action hook, so the host action's
notification mode governs.

Outbox re-admission carries the original metadata after process restarts.
Delivery-only `reconcile_pending/3` remains the backstop and reconstructs an
event with empty metadata. Routes must tolerate that delivery-only contract.
Durable queue admission must be idempotent; transport remains at-least-once.

Before rolling back to a library version without the outbox, stop new
publications and drain or explicitly park and inspect all pending rows. Keep
outbox tables, routes, builders and grants until every retained obligation is
resolved. An older library cannot sweep new-format rows. A rollback must retain
a compatible fanout deployment until those obligations finish; dropping the
outbox would lose them. Re-enable publication only with a compatible reader.

### Subscription index

On PostgreSQL, add a GIN index on each subscription table's `event_types`
column using the migration generator's custom-index support. Keep tenant
indexes and the resource's primary-read filters and preparations. The type
predicate casts both arrays to `text[]`; metadata selection widens numeric
and structured values to the final Elixir predicate. The optimization applies
to immediate dispatch and transactional fanout alike.

<a id="upgrade-3-3"></a>

## 3.2.0 → 3.3.0

Applications using HTTP ingress must update Plug to 1.20.4 or later in the 1.x
series. Earlier versions are excluded because of CVE-2026-120287 in multipart
parsing. Plug remains optional for applications that do not use HTTP ingress.

The qualified Spark floor is 2.7.6, the minimum required by Ash 3.37.2.
Update Spark alongside Ash if your lock contains an older version. The floor
check resolves both exact versions against a fresh dependency graph.

### Host extension seams

Each schema change is opt-in. Apply the migration before enabling the matching
option on the resource, and deploy every process that reads that resource with
the same DSL declaration. Existing resources and adapters require no migration
when all new options stay at their defaults.

- For `inbound_delivery` with `record_verified_facts :on`, add nullable
  `verified_facts` as an Ash map (PostgreSQL JSONB, SQLite JSON text). Keep it
  sensitive in policies and exports. Existing receipts remain null; new valid
  facts persist with the first authenticated receipt. Redaction clears them.
- For `outbound_attempt` with `record_signing_provenance :on`, add nullable
  `signing_key_refs` as an array of strings (PostgreSQL text array, SQLite JSON
  text). Existing attempts remain null. The existing singular field stays.
- Before `endpoint` with `native_signing :optional`, relax the endpoint table's
  `secret_ref` NOT NULL constraint. PostgreSQL can drop that constraint with
  `ALTER TABLE`; SQLite requires a table rebuild using the data layer's
  migration generator. Preserve every index, foreign key and tenant constraint.
  Keep `native_signing :required` on resources that need mandatory native keys.
- Declare the host-owned signer reference and scheme attributes on the endpoint
  resource and migrate them through the data layer normally. List all attributes
  that determine signing in `signer_attributes`. These attributes cannot be
  sensitive, and their stored values must round-trip through their Ash types.
  Store references, never credentials. No package signer columns are injected.

For PostgreSQL, the nullable-column changes have this shape; replace the table
names with the tables declared by your resources:

<!-- tested: upgrade-host-extension-columns -->
```sql
ALTER TABLE inbound_deliveries ADD COLUMN verified_facts jsonb;
ALTER TABLE outbound_attempts ADD COLUMN signing_key_refs text[];
ALTER TABLE webhook_endpoints ALTER COLUMN secret_ref DROP NOT NULL;
```

For SQLite, add `verified_facts TEXT` and `signing_key_refs TEXT` to the
corresponding tables. Generate the endpoint table rebuild from the resource's
complete schema, changing only `secret_ref` nullability. A generic rebuild
cannot name all host-owned columns, constraints and indexes, so use the
application's migration generator and inspect its preservation of those fields.
The extension's database tests apply both additive columns and the dialect's
nullability migration before writing facts, provenance and host-only endpoints.

Use `AshHooks.Endpoint.enable_native_signing/2` and `disable_native_signing/2`
for custody endpoints that opted into optional native signing. These operations
retain issuance and durable disposal through the key registry. They require the
explicit tenant and run outside enclosing transactions. Do not clear custody
references with an ordinary resource update.

A host signer requires a prepared-capable HTTP adapter or transport. Bounded
supports it. Httpc does not support it: raw-listener qualification found that
`:httpc` normalizes percent escapes in the signed target even with `headers_as_is`.
Custom adapters must send the supplied method, target, ordered complete header
lines and body unchanged, without additional framing or headers. Keep their
legacy `request/5` implementation for callers without prepared requests.

Review observability consumers for the corrected singular signing reference in
legacy mode, `signer_failed`, `unsigned`, `adapter_cannot_send_prepared`, and the
`[:ash_hooks, :delivery, :sign]` event. New event-log replay rows use a matching
subscription's signing mode across all read pages. With no match they retain
`:standard`; only conflicting matching modes are skipped. Older 410 snapshots
without every declared signer
attribute finalize without disabling a reconfigured endpoint.

### Oban with forced row security

The optional Oban requirement is now `~> 2.24`. Upgrade Oban before using the
service configuration below.

If Oban currently runs queues through the ledger's runtime repository with
only a tenant-keyed job policy, separate insertion from execution before
resuming queues. Follow the [row-security guide](documentation/tutorials/row-security.md)
to provision a restricted engine role and repository, force row security on
both `oban_jobs` and `oban_peers`, and apply their role-specific grants and
policies. Remove older policies and grants that widen access. Keep the worker's
`oban:` option on the runtime repository's insert-only instance, with queues,
plugins, peer leadership, and staging disabled. Run queues and maintenance on
the engine instance with the same database, prefix, and PostgreSQL notifier.
Existing job arguments and delivery rows need no conversion.

<a id="upgrade-3-2"></a>

## 3.1.0 → 3.2.0

For a first implementation, read [key custody and lifecycle](documentation/tutorials/key-custody.md)
and run the [Livebook](documentation/livebooks/get-started.livemd). This section
covers the schema and operational changes for existing applications.

To adopt the inbound lifecycle:

1. Create an `AshHooks.InboundSource` resource with the ledger's tenancy,
   locally declared scope, provider allowlist, custodian, and key registry.
   Source and ledger must both be single-tenant or use attribute tenancy with
   the same attribute name and type. Scope names, types, constraints, and
   nonnullable attributes must agree. Migrate the injected source columns.
2. Create one source row per declaration and scope under each tenant using
   `create_source/3`. Import the sender's current material and kind, optionally
   its previous material and required retirement time, or pin its public key.
   Generation supports only `{:standard_webhooks, :v1}` and returns a one-time
   `whsec_` disclosure. Imported material is the key bytes for its recorded kind.
3. Declare ledger `record_provider_alias :on`, generate and apply the nullable
   atom `provider_alias` migration, then activate the `source_record` declaration
   naming the source resource. New receipts then record the provider alias.
4. Run `AshHooks.InboundSource.adopt_provider_alias/4` for every source under
   its tenant, with `expected_provider:` naming the old declaration's module.
   Repeat bounded calls until `remaining` is zero. A live pre-switch claim can
   keep it positive until finalization or lease expiry. Older nil-alias receipts
   wait unclaimed until adoption; terminal receipts need no alias. Deduplication
   identities do not change. Each claim uses the stored alias and scope without
   reading the source, including after deletion, pause, rotation, or alias selection changes.

Alias adoption returns `:invalid_limit` for a nonpositive or noninteger limit,
`:source_mismatch` when the declaration does not use the source resource, and
`:provider_mismatch` for an unknown alias or a mismatched `expected_provider`.
Correct these arguments before retrying.

All inbound declarations, including existing declarations without `source_record`,
now cast scope values through the ledger attributes and apply their constraints
before verification. Missing, nil, or invalid values return `MalformedPayload`.
Review route resolvers and providers that inspect scope: they now receive cast
values instead of the original request values.

Source creation, roll, reissue, and alias adoption return `:inside_transaction`
inside an enclosing transaction; call them after it commits. `:kind_not_allowed`
means that generation or reissue cannot generate the requested kind and issued
nothing. Sender HMAC keys must be imported. `:owner_mismatch` means the create
action did not persist one owner holding every issued reference and kind; its
write rolled back. `:key_issue_expired` means a registry sweep or tombstone won
before attachment; repeat for a fresh reference. For `:overlap_active`, wait for
the deadline or expire the previous key. For `:previous_secret_undated`, schedule
its retirement or expire it; waiting alone cannot resolve it.
An absent source row returns `UnknownSource` (HTTP 404), distinct from an invalid
signature. A lost generated disclosure can be replaced with
`AshHooks.InboundSource.reissue_secret/2`; it preserves the previous key and deadline.

Optional provider callbacks `parse_event_type/2`, `event_identity/2`, and
`handle_event/3` receive `AshHooks.Provider.DeliveryContext` and take precedence
over the existing arities. Parsing and identity receive nil delivery IDs;
handling receives the stored IDs on ingest and recovery. Tenant, declaration
name, scope, and provider alias are available in both phases. Existing arities
remain supported, including declarations without a source resource.

To move outbound endpoints from byte references to custody:

1. Enable `key_lifecycle :on` and migrate its columns. To adopt legacy slots,
   also enable `legacy_key_lifecycle :on` and migrate its timestamps and kind
   columns. Before adoption, schedule every undated previous key in each enabled
   slot with `schedule_previous_retirement/3`, or remove it with
   `expire_previous_secret/2`.
2. Add a key-registry resource on the same transactional data layer,
   repository used for writes, and tenancy as the endpoint. Migrate the registry and per-slot
   kind columns described below. Declare `custodian` and `key_registry` while
   keeping the endpoint's `secret_resolver`.
3. Create new endpoints with `AshHooks.Endpoint.create_with_key/3`, supplying
   `generate: {:standard_webhooks, :v1}`, `generate: {:standard_webhooks, :v1a}`,
   or `material:` in the signing API's wire format. Generation returns
   `{:ok, endpoint, disclosure}`; import returns `{:ok, endpoint}`. v1 discloses
   the `whsec_` secret; v1a discloses only the `whpk_` public half.
4. Run `AshHooks.Endpoint.adopt_keys/2` for every existing row under its tenant.
   Occupied standard current and previous byte slots convert together, with
   lifecycle timestamps unchanged. Legacy slots also convert with
   `legacy_key_lifecycle :on`; otherwise they stay host byte references and keep
   signing through `secret_resolver`. Already adopted slots are left alone,
   so adoption is resumable. Original host references never enter the registry.
5. Keep `secret_resolver` while any occupied slot has no kind marker, including
   legacy slots without lifecycle tracking. After adopting every occupied slot, remove
   `secret_resolver`, remove byte material from the host's store, and optionally
   enable `key_material: :custody_only`.

Custody rolls accept exactly one of `material:` or `generate: kind`; endpoints
that retain a byte resolver also accept the existing `new_secret_ref:` path.
Standard slots generate v1 or v1a; legacy slots generate
`{:legacy_hmac, :sha256}` with `slot: :legacy`. Legacy generation discloses the
exact 32 random key bytes as a binary. Do not encode those bytes and then use
the encoding as a different legacy key. Sender HMAC kinds are never generated
or imported into endpoint slots. The overlap gate and retirement deadlines
apply to custody and byte keys alike.

Run issuing operations outside an enclosing transaction. They commit the
registry issue before calling custody, then create or update the owner and
attach the issue in one transaction. A failed attempt retires its issues;
after a process crash, the registry sweep retires timed-out issues and destroys
them. Schedule that sweep as described below and repeat the failed operation.

When a committed generation's one-time disclosure is lost, call
`AshHooks.Endpoint.reissue_secret/2` with the selected `slot:`. It returns
`{:ok, endpoint, disclosure}` for a newly generated current key of the same kind.
The replaced current key stops signing immediately, cutting off a counterparty
that holds only that key. The previous key and its retirement time are unchanged;
only that previous key continues through its existing window. Reissue ignores
the overlap gate, creates no new overlap, and refuses byte slots with `:byte_slot`.

Handle these issuance refusals explicitly:

| Result | Meaning and recovery |
| --- | --- |
| `:inside_transaction` | Invoke issuance after the enclosing transaction commits. Nothing was issued. |
| `:key_issue_expired` | The registry sweep won before attachment, or custody already tombstoned the issue. Repeat the operation for a fresh reference. |
| `:kind_not_allowed` | This slot cannot generate or import that kind. Use a supported signing kind. Nothing was issued. |
| `:owner_mismatch` | The create action did not persist exactly one owner holding every issued reference in its intended slot and kind. Fix the action before retrying; its write rolled back. |

Custody endpoints now sign through the endpoint resource's `custodian`, including
worker deliveries and `test_send`. Current and previous Standard Webhooks slots
may use different algorithms. Legacy slots use custody with
`legacy_key_lifecycle :on`. Each slot's kind marker is authoritative: a nonnull
marker selects custody, while a null marker selects the endpoint's
`secret_resolver {module, function}` or the delivery or worker resolver. Keep a
byte resolver during migration until every occupied slot has a custody marker.
An occupied unmarked slot without a resolver fails permanently as
`key_kind_mismatch`; sender HMAC kinds are refused as `kind_not_allowed`.
Existing byte signing APIs remain supported.

For custody keys held by an endpoint or inbound source record, `UnknownKey`
with a reference triggers one owner reread. If that reference has been replaced
and is no longer among the admitted keys, signing or verification retries with
the refreshed keys. An unchanged missing reference is not retried, and there
is no repeated refresh loop. Outbound refresh updates signing metadata while
preserving the destination authorized for that attempt.

Custody tenant metadata is derived from the owner row inside its database phase,
independently of a serialized job's tenant spelling. An endpoint whose tenant
type is not UUID, UUIDv7, integer, string, or ci_string must declare
`custody_tenant_key {module, function, args}`. The MFA receives the cast tenant
value followed by its arguments and must return equal UTF-8 binaries whenever
the database treats two tenants as equal. This equality contract belongs to the
host and applies to issuance, attachment, and signing. Unsupported types without
the option fail compilation.

Set `config :ash_hooks, key_material: :custody_only` before compiling resources
and providers to refuse byte sources. The setting is off by default. It refuses
endpoint and worker `secret_resolver`, inbound `secret` and `previous_secret`
in every supported source shape, and provider `webhook_signing_secret/1` and
`webhook_signing_secret/2` implementations. A custody worker omits its byte
resolver and reads custody configuration from the endpoint. Direct byte signing
and verification functions remain supported APIs.

Inbound HMAC primitives and configured HMAC providers accept
`AshHooks.Custody.Key` values and rotation lists mixing opaque keys and bytes.
Signature encodings are decoded before verification; configured key encodings
apply only to byte keys. Public RSA, ECDSA, and Ed25519 verification keys remain
outside custody. Classified custody failures reach ingress, Plug, and telemetry
without backend terms. `UnknownSource` returns HTTP 404. Missing keys and kind
mismatches are configuration failures (HTTP 500 and permanent delivery failures); unavailable custody and
unexplained answers return HTTP 503 and retry delivery. Invalid authentication
retains its existing response. Unavailable custody and unrecognized callback
failures do not create failed-verification rejection rows or increase that
rejection count. Paused sources are also excluded.

Package database operations now open bounded tenant phases through
`Ash.transact/3`. An RLS host configures its repository's
`on_transaction_begin/1` to derive transaction-local settings from
`reason[:tenant]` using `set_config(name, value, true)`. Row-secured package
tables must use Ash multitenancy, and host-scheduled sweeps run per tenant
with `tenant:`. Configure the worker's Oban instance for insertion on the ledger
repo, with tenant-keyed runtime policies on `args->>'tenant'`. Run queues and
maintenance on a separate engine-role repo with policies over all rows of both
Oban tables. Bind an enclosing host transaction once, with the same tenant. See the
[row-level security guide](documentation/tutorials/row-security.md).

On AshPostgres and transactional AshSqlite resources, package reads now use
the write repository inside their phase. If the host's `repo` function routes
`:read` operations elsewhere, package phase reads still use the write repository,
where the transaction and tenant binding exist. Data layers without
transactions retain their behavior and are not RLS-capable.

`AshHooks.Delivery.run/2` and `test_send/2` now return
`{:error, :inside_transaction}` before starting a process or accessing the
database when the delivery resource has an enclosing transaction. Their
monitored child cannot join the caller's connection or see its uncommitted
rows. Enqueue a job and perform it after commit. A dispatch whose enqueue
callback invokes the driver inline inside a host transaction reports
`:enqueue_failed` for that endpoint and records that state for recovery.
The child retains the attempt deadline and configured tracer context.

Inbound ledgers can configure `json_decoder` in `inbound_delivery` with an MFA
`{module, function, args}`. It receives JSON bytes followed by `args` and must
return `{:ok, map_or_list}` or `{:error, reason}`. The default is
`{Jason, :decode, []}`. Ingress supplies one decoder per request to verification
and payload decoding; JWS protected headers, claims, and delivery use that
decoder, with claims and delivery interpreting the same payload bytes without
a cache. Decoder errors, exceptions, and non-map, non-list values are malformed
payloads, recorded by `:record_malformed` as described under 3.0.0 → 3.1.0. A
protected header the decoder refuses cannot be verified and is an invalid
signature; malformed claim types remain invalid signatures.

Before configuring this option, add `decode_payload/2` to any provider with a
host-defined `decode_payload/1`, including overrides emitted by compile hooks.
Use only the supplied function for JSON decoding, including JSON inside an
envelope. The ledger's compile-time verifier refuses a host `/1` without `/2`,
even when explicitly configuring the default MFA. A generated JWS `/1` is
exempt and uses the request's decoder in ingress, independently of verifier
overrides. Direct calls to a generated `/1` still use `Jason.decode/1`.

This provider preserves its direct-call decoder and honors request policy:

<!-- tested: upgrade-json-decoder-provider -->
```elixir
defmodule MyApp.Webhooks.JsonProvider do
  use AshHooks.Provider,
    verify: [algorithm: :hmac_sha256, signature: {:header, "x-orders-signature"}]

  @impl true
  def decode_payload(bytes), do: Jason.decode(bytes)

  @impl true
  def decode_payload(bytes, json_decoder), do: json_decoder.(bytes)
end
```

Run `AshHooks.Provider.Conformance` with `provider: YourProvider` in your test
suite to check the supplied-decoder contract. For envelopes, pass
`payload: verified_bytes` matching the provider's input and test each supported
shape. The template compiles without ExUnit in the package's runtime dependencies.

Decode precedence is unchanged: an explicit inbound `body_format`, then the
provider's decoder, then `body_format/0`, then JSON. For a host-defined decoder,
`decode_payload/2` precedes `/1`; a generated decoder uses its scheme with the
request policy. Explicit `body_format` on a JWS route still decodes the compact
token as the specified format. Ledgers without `json_decoder` keep accepting
existing providers and use the default JSON policy.

Subscriptions can opt in to `pausable :on` in their `subscription` section.
Before enabling it, migrate the subscription table to add `paused`, a boolean
column with `NOT NULL` and default `false`, including existing rows. Applications
pause and resume through their own update actions accepting `paused`, with their
own authorization policies and tenant scope. Pausing prevents new delivery rows;
it does not cancel existing deliveries. The default `pausable :off` adds no
attribute and requires no migration.

IPv6 destinations in reserved or unallocated address space are now refused,
including unallocated gaps inside `2000::/3`. Registration and send-time checks
use the IANA allocation table retrieved November 13, 2026. New IANA allocations
require a package update before admission. Existing globally reachable
special-purpose exceptions and IPv4 classification are unchanged.

`AshHooks.Ssrf.resolve_host_public/2` adds the same public-address check for DNS
names and IP literals without requiring an HTTP URL. Call it at every connect,
reconnect, redirect, failover, and broker-advertised address. Connect only to a
returned address and keep the original name for TLS verification and server name
indication. Its two-second resolution ceiling can be shortened with an absolute
monotonic millisecond `:deadline`; destination policies cannot bypass this check.

Key-custody implementers can adopt the `AshHooks.Custody` behavior and run
`AshHooks.Custody.Conformance` against a fresh real store in their test suite.
The contract requires global reference uniqueness, atomic tenant binding,
kind assertions, and permanent tombstones. ExUnit is needed only in tests.
`AshHooks.Custody.canonical_tenant/3` follows the owner's Ash create path;
types other than UUID, UUIDv7, integer, string, and ci_string require an
equality-preserving `custody_tenant_key` MFA option. The module documentation
defines the callback and canonicalization contracts.

For durable custody disposal, add a host Ash resource with
`extensions: [AshHooks.KeyRegistry]`. Configure its table and write repository
with the host's `postgres` or `sqlite` section and register it in the host domain.
The registry and every owner must use the same data layer and write repository,
with transaction support, and the same multitenancy strategy and tenant
attribute type. SQLite repos must enable `write_transactions?/0`. Function
repos are checked at each transition, including their dynamic repo instance;
a mismatch returns a configuration error before the transition writes.

Generate and apply the registry migration before declaring it on an endpoint.
The registry requires `ref` as its sole primary key; omit a generated `id` primary key.
The extension injects these columns in addition to the host's tenant attribute:

| Columns | Ash type and database requirements |
| --- | --- |
| `ref` | `:string`, primary key, not null, up to 40 characters |
| `kind` | `:term`, binary (`bytea` on PostgreSQL, `blob` on SQLite), not null |
| `owner_resource` | `:atom`, text, not null; retains the issuing resource module |
| `owner_key` | `:map`, nullable JSON; complete persisted primary key, set on attachment |
| `state` | `:atom`, text, not null, default `issued`; admits `issued`, `attached`, `retired`, `destroy_failed`, `destroyed` |
| `custody_tenant` | `:string`, nullable canonical custody tenant; separate from the database tenant attribute |
| `issued_at`, `inserted_at`, `updated_at` | `:utc_datetime_usec`, not null |
| `destroy_after`, `next_attempt_at` | `:utc_datetime_usec`, nullable |
| `attempts`, `destroy_generation` | `:integer`, not null, default zero, non-negative |
| `last_error` | `:string`, nullable, at most 64 characters; fixed classification only |

Keep resource modules named by registry rows available until their obligations
have been destroyed and pruned. The optional registry DSL setting
`issue_timeout` is seconds, defaulting to 900 (15 minutes). Set it longer than
the custodian's store timeout. Registry rows exist before custody receives a
reference, so a crashed or timed-out issuance can still be destroyed. Permanent
custodian tombstones refuse delayed stores after timeout destruction.

On outbound owners, declare `custodian` with the custody module and
`key_registry` with the new resource. Both require `key_lifecycle :on`.
First migrate nullable binary `:term` columns `secret_kind` and
`previous_secret_kind`. With `legacy_key_lifecycle :on`, also migrate
`legacy_secret_kind` and `legacy_previous_secret_kind`. A kind marks that
slot as a custody reference. Existing byte references keep null kinds and
their existing resolver; do not mark them as custody references. Rolling
moves a kind together with its reference. Expiration, the lifecycle sweep,
and rolling past an ended window retire displaced custody references in the
same transaction as the owner write. Byte references never enter custody
or the registry.

Schedule `AshHooks.KeyRegistry.sweep/2` beside the lifecycle sweeps for every
tenant. Pass `:tenant` on multitenant resources and an optional UTC `:now` for
an application clock. The registry sweep refuses an enclosing transaction
with `{:error, :inside_transaction}`. It commits each retirement or owner
reconciliation before calling custody outside any transaction. It handles
owner actions, bulk deletion, cascades, direct SQL, and replacement of a
slot reference. A rollback of an owner write also rolls back its retirement.
Disposal uses the row's stored `custody_tenant` after owner deletion.

The registry injects `:read`, `:issue_key`, `:transition_key`, and `:prune_keys`
when the host has not supplied them. Restrict direct access to the machine write
actions; `AshHooks.KeyRegistry` lists their input contracts. Retirement returns
`:key_not_attached` when the registry reference is not attached, and the owner
write rolls back. Repair the owner/registry inconsistency before retrying.

Custody owners receive the reserved system read action `read_custody_owner`.
It has no action filter, preparation or pagination, so a host primary read
that hides a live owner cannot cause disposal. The resource's `base_filter`
still applies: a row it hides counts as gone. Lifecycle retirement reads the
persisted owner after a write and retains a reference held in any slot.
Refusals before a write leave an enclosing host transaction usable; failures
after an owner write roll back the write and its retirement together.

Unavailable custody is retried with exponential delay capped at one hour.
Other destroy answers move the obligation to `destroy_failed`, counted in
the sweep result and reported through
`[:ash_hooks, :key_registry, :destroy_failed]`. Alert on that event and inspect
`AshHooks.KeyRegistry.pending/2` with the tenant. After repairing the cause,
call `AshHooks.KeyRegistry.rearm/3` with the registry, reference, and tenant.
It resets retry state and increments `destroy_generation`, fencing answers
already in flight. Automatic sweeps skip failed rows until they are rearmed.
Schedule `AshHooks.KeyRegistry.prune/2` with `before: timestamp` to remove
destroyed audit rows by age. It never removes pending obligations or the
custodian's permanent tombstones. These operator functions perform system
operations; apply host authorization before exposing them to callers.

A raised exception, exit or missing custodian also parks only that reference
as `destroy_failed`, with the fixed `unclassified` error and telemetry reason.
Exception contents do not escape, and subsequent references are still swept.
Unavailable retry results are fenced by both generation and the read attempt
count, so delayed results cannot overwrite newer retry state.

`AshHooks.Signing.display_fingerprint/1` accepts spec-shaped key strings;
`AshHooks.Custody.display_fingerprint/1` accepts opaque spec keys. Ed25519
private and public halves display the same fingerprint. Sender and legacy
material has no display fingerprint. Show fingerprints only for securely
generated keys; they do not protect weak secrets from offline guessing.

Unrecognized provider reasons now return a contents-free `UnknownError`
instead of raising. The new `UnknownSource`, `KeyKindMismatch`, `UnknownKey`,
and retryable `KeyUnavailable` classes have fixed telemetry reason tokens.

Transport resolver failures now refuse the attempt instead of falling back to
HTTP. A resolver that raises, throws, exits, or returns anything other than `nil`
or a transport module exporting `request/5` causes a retryable
`transport_resolution` failure. Delivery rows, attempt history, and telemetry
retain only this fixed classification, without the error contents.

If your resolver relied on HTTP fallback after a failure or an invalid return,
change it to return `nil` explicitly when HTTP is intended. Fix failing resolvers
to return a transport module or `nil`; failed attempts retry under the delivery
row's existing retry policy and attempt ceiling.

With `key_lifecycle :on`, a standard previous signing key stops signing at
`previous_secret_retired_at`, using the delivery's configured application
clock. A delayed retirement sweep no longer extends its signing window, and
the secret resolver is not called for that retired reference. Keep scheduling
`AshHooks.Endpoint.expire_previous_secrets/2` to remove expired references.
First-use timestamps record only keys that signed and cannot stamp replacement
references during a concurrent roll. Attempt history still identifies the
current signing key, and telemetry payloads are unchanged.

When adopting lifecycle tracking, an existing `previous_secret_ref` with no
retirement time remains undated. It continues signing, the sweep skips it,
and `AshHooks.Endpoint.roll_secret/2` returns
`{:error, :previous_secret_undated}`. Set an explicit retirement time with
`AshHooks.Endpoint.schedule_previous_retirement/3`, or retire it immediately
with `AshHooks.Endpoint.expire_previous_secret/2`. Scheduling accepts a
`DateTime` at or after the application clock; a past time returns
`{:error, :retirement_in_past}`, and a missing previous reference returns
`{:error, :no_previous_secret}`. Supply `:now` consistently when using an
application clock and `:tenant` for multitenant resources. No retirement date
is inferred from deployment time.

A roll inside an active overlap now returns `{:error, :overlap_active}`
without changing the endpoint. To roll again immediately, call
`AshHooks.Endpoint.expire_previous_secret/2`, then roll. This ends the old
key's signing window immediately. Once a dated window ends, rolling is
allowed even if the retirement sweep has not removed the old reference.

The `:overlap_seconds` option must be a non-negative integer; other values
return `{:error, :invalid_overlap}`. Zero cuts off the previous key at the
roll instant. The `endpoint` DSL accepts optional `max_overlap_seconds`
(a positive integer) and `default_overlap_seconds` (a non-negative integer).
The default remains 86,400 seconds when unset. Compilation refuses a maximum
below the effective default. A roll above the maximum, or retirement
scheduling beyond that many seconds from the application clock, returns
`{:error, {:overlap_exceeds_max, max}}`.

Legacy lifecycle tracking is optional. Resources that leave
`legacy_key_lifecycle :off` retain their existing schema and legacy signing
behavior. To opt in, first migrate five nullable `utc_datetime_usec` columns:
`legacy_secret_created_at`, `legacy_secret_first_used_at`,
`legacy_previous_secret_created_at`, `legacy_previous_secret_first_used_at`,
and `legacy_previous_secret_retired_at`. Then declare both
`key_lifecycle :on` and `legacy_key_lifecycle :on` under `endpoint`.
Compilation refuses the legacy option without the standard lifecycle option.
No timestamp is inferred for existing legacy keys.

The four endpoint lifecycle helpers (`roll_secret/2`,
`schedule_previous_retirement/3`, `expire_previous_secret/2`, and
`expire_previous_secrets/2`) accept `slot: :legacy` to operate on legacy keys.
They default to `slot: :standard`. Each changes only its selected slot; run
retirement sweeps for both enabled slots. Overlap defaults and caps apply to
both. An empty legacy incumbent installs the new key without a previous key.
A new reference matching the selected slot's incumbent or previous reference
returns `{:error, :same_reference}`.

A dated legacy previous key stops signing at its retirement instant, before
any sweep. Undated legacy previous references keep signing, block rolling,
and are skipped by the sweep until scheduled or expired. The injected
`:mark_legacy_current_secret_used` and `:mark_legacy_previous_secret_used`
actions stamp only keys that signed, using atomic reference checks to avoid
stamping replacements during a concurrent roll. Authorize application callers
before exposing any lifecycle helpers; they perform system writes after the
same tenancy preflight as the standard slot.

## 3.0.0 → 3.1.0

The Ash floor rises from 3.34.3 to 3.37.2, because three published advisories
affect Ash releases the old floor admitted (EEF-CVE-2026-101028, -114214 and
-96581). If your lock holds Ash below 3.37.2, update Ash first:

<!-- not-run: This changes an adopter's project dependencies and lockfile. -->
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
on the repo. Early key retirement records its actual time. In 3.1.0, a previous
key continued signing until its reference was removed. Starting in 3.2.0,
lifecycle-tracked previous keys stop signing at their retirement deadline,
even before removal.

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

Replace each removed module with a provider in your application. On each existing
`inbound` declaration, change only `provider` to the application module shown
below. Keep the source name, scope, tenant resolution, secret source, and any
explicit `event_id` extractor. The source-name rule immediately above applies to
every recipe; the application module name does not select the source name.

Unless a recipe says otherwise, the generated callbacks keep the former
`:webhook` classification, return `AshHooks.Provider.Event`, and leave delivery
identity as the SHA-256 digest of the raw request body. The two former nested
`Event` structs are replaced by `AshHooks.Provider.Event`, with the same `type`
and `payload` fields. Update any application struct patterns accordingly.

Pass the exact raw body and ordered request headers to ingress. For a scheme
that signs the URL or method, also pass the original HTTP method and public
request URI, preserving percent encodings, query order, scheme, host, and port.
Behind a proxy, use the application's configured public base URL as described in
the [verification guide](documentation/tutorials/verify-any-sender.md).

The blocks below are executed by the known-answer recipe tests. The
[generic verification guide](documentation/tutorials/verify-any-sender.md) covers
scheme options and host integration. The historical 2.3.0
[event-type mapping source](https://github.com/baselabs/ash_hooks/blob/v2.3.0/lib/ash_hooks/provider/comply_cube.ex)
and [batch-provider source](https://github.com/baselabs/ash_hooks/blob/v2.3.0/lib/ash_hooks/provider/hub_spot_v3.ex)
remain available for comparison. Before changing an identity, follow the
[legacy identity adoption procedure](#adopt-a-canonical-provider-identity).

#### ComplyCube

Replace `AshHooks.Provider.ComplyCube` with `MyApp.Webhooks.IdentityChecks`.
The lowercase hex body signature has no timestamp. Keep the complete finite
mapping below; unknown types fail closed without creating atoms from input.
Delivery identity remains the raw-body digest.

<!-- tested: upgrade-identity-checks-provider -->
```elixir
defmodule MyApp.Webhooks.IdentityChecks do
  use AshHooks.Provider,
    verify: [algorithm: :hmac_sha256, signature: {:header, "complycube-signature"}]

  @event_types %{
    "client.created" => :client_created,
    "client.updated" => :client_updated,
    "client.deleted" => :client_deleted,
    "document.created" => :document_created,
    "document.updated" => :document_updated,
    "document.updated.image_uploaded" => :document_updated_image_uploaded,
    "document.updated.image_deleted" => :document_updated_image_deleted,
    "document.deleted" => :document_deleted,
    "address.created" => :address_created,
    "address.updated" => :address_updated,
    "address.deleted" => :address_deleted,
    "check.pending" => :check_pending,
    "check.completed" => :check_completed,
    "check.completed.clear" => :check_completed_clear,
    "check.completed.attention" => :check_completed_attention,
    "check.completed.rejected" => :check_completed_rejected,
    "check.completed.match_confirmed" => :check_completed_match_confirmed,
    "check.monitoring.attention" => :check_monitoring_attention,
    "check.failed" => :check_failed,
    "check.updated" => :check_updated,
    "workflow.session.started" => :workflow_session_started,
    "workflow.session.cancelled" => :workflow_session_cancelled,
    "workflow.session.processing" => :workflow_session_processing,
    "workflow.session.completed" => :workflow_session_completed,
    "workflow.session.updated" => :workflow_session_updated
  }

  @impl true
  def parse_event_type(%{"type" => raw}) when is_binary(raw) do
    case Map.fetch(@event_types, raw) do
      {:ok, type} -> {:ok, type}
      :error -> {:error, :unknown_event_type}
    end
  end

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  @impl true
  def handle_event(event_type, payload) do
    {:ok, %AshHooks.Provider.Event{type: event_type, payload: payload}}
  end
end
```

#### Shopify

Replace `AshHooks.Provider.Shopify` with `MyApp.Webhooks.Storefront`.
Use the signing secret as raw bytes. The signature is a base64 body HMAC.
Keep the raw-body delivery identity.

<!-- tested: upgrade-storefront-provider -->
```elixir
defmodule MyApp.Webhooks.Storefront do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-shopify-hmac-sha256"},
      encoding: :base64
    ]
end
```

#### WooCommerce

Replace `AshHooks.Provider.WooCommerce` with `MyApp.Webhooks.StoreOrders`.
Use the signing secret as raw bytes. The signature is a base64 body HMAC.
Keep the raw-body delivery identity.

<!-- tested: upgrade-store-orders-provider -->
```elixir
defmodule MyApp.Webhooks.StoreOrders do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-wc-webhook-signature"},
      encoding: :base64
    ]
end
```

#### Stripe

Replace `AshHooks.Provider.Stripe` with `MyApp.Webhooks.Payments`.
The structured header supplies `t` and one or more `v1` signatures over
`timestamp.body`. The default replay window is 300 seconds in either direction;
the declaration's `replay_window_seconds` overrides it. Keep the raw-body identity.

<!-- tested: upgrade-payments-provider -->
```elixir
defmodule MyApp.Webhooks.Payments do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:structured_header, "stripe-signature", signature_key: "v1"},
      timestamp: {:signature_field, "t"},
      signed_input: [:timestamp, ".", :body]
    ]
end
```

#### Shippo

Replace `AshHooks.Provider.Shippo` with `MyApp.Webhooks.ShippingRates`.
The structured header supplies `t` and one or more `v1` signatures over
`timestamp.body`. The default replay window is 300 seconds in either direction;
the declaration's `replay_window_seconds` overrides it. Keep the raw-body identity.

<!-- tested: upgrade-shipping-rates-provider -->
```elixir
defmodule MyApp.Webhooks.ShippingRates do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:structured_header, "shippo-auth-signature", signature_key: "v1"},
      timestamp: {:signature_field, "t"},
      signed_input: [:timestamp, ".", :body]
    ]
end
```

#### Squarespace

Replace `AshHooks.Provider.Squarespace` with `MyApp.Webhooks.SiteEvents`.
The secret is a hex-encoded key; decode it before computing the body HMAC.
Keep the raw-body delivery identity.

<!-- tested: upgrade-site-events-provider -->
```elixir
defmodule MyApp.Webhooks.SiteEvents do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "squarespace-signature"},
      key_encoding: :hex
    ]
end
```

#### Ecwid

Replace `AshHooks.Provider.Ecwid` with `MyApp.Webhooks.CatalogEvents`.
Only `eventCreated.eventId` is authenticated, not the rest of the body.
Preserve `eventId` as the delivery identity, including nonnegative integer IDs.
There is no authenticated replay timestamp.

<!-- tested: upgrade-catalog-events-provider -->
```elixir
defmodule MyApp.Webhooks.CatalogEvents do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-ecwid-webhook-signature"},
      encoding: :base64,
      signed_input: {__MODULE__, :signed_input}
    ]

  def signed_input(body, ctx) do
    decoder = Map.get(ctx, :json_decoder, &Jason.decode/1)
    {:ok, %{"eventCreated" => timestamp} = payload} = decoder.(body)
    true = is_integer(timestamp) and timestamp >= 0
    {:ok, id} = event_identity(payload)
    Integer.to_string(timestamp) <> "." <> id
  end

  @impl true
  def event_identity(%{"eventId" => id}) when is_binary(id) and id != "", do: {:ok, id}

  def event_identity(%{"eventId" => id}) when is_integer(id) and id >= 0,
    do: {:ok, Integer.to_string(id)}

  def event_identity(_payload), do: {:error, :malformed_payload}
end
```

#### HubSpotV3

Replace `AshHooks.Provider.HubSpotV3` with `MyApp.Webhooks.CrmEvents`.
The app client secret signs the method, selectively decoded public URI, raw
body, and millisecond timestamp. The default replay window is 300 seconds in
either direction, overridden by `replay_window_seconds` on the declaration.

Keep the finite subscription map and complete batch identity below. Homogeneous
batches keep their mapped type; mixed known types become `:mixed`. Unknown types
and malformed or empty batches fail closed. The identity ignores only outer
`attemptNumber`, sorts object keys and outer events, and preserves repeated
events and nested list order. It retains the former namespace bytes. Replace
calls to the removed `decode_request_uri/1` with the application function shown.

<!-- tested: upgrade-crm-events-provider -->
```elixir
defmodule MyApp.Webhooks.CrmEvents do
  alias AshHooks.Provider.Signature

  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-hubspot-signature-v3"},
      encoding: :base64,
      signed_input: {__MODULE__, :signed_input},
      timestamp: {:header, "x-hubspot-request-timestamp"},
      timestamp_unit: :milliseconds
    ]

  @subscription_types %{
    "contact.creation" => :contact_creation,
    "contact.deletion" => :contact_deletion,
    "contact.merge" => :contact_merge,
    "contact.associationChange" => :contact_association_change,
    "contact.restore" => :contact_restore,
    "contact.privacyDeletion" => :contact_privacy_deletion,
    "contact.propertyChange" => :contact_property_change,
    "company.creation" => :company_creation,
    "company.deletion" => :company_deletion,
    "company.propertyChange" => :company_property_change,
    "company.associationChange" => :company_association_change,
    "company.restore" => :company_restore,
    "company.merge" => :company_merge,
    "deal.creation" => :deal_creation,
    "deal.deletion" => :deal_deletion,
    "deal.associationChange" => :deal_association_change,
    "deal.restore" => :deal_restore,
    "deal.merge" => :deal_merge,
    "deal.propertyChange" => :deal_property_change,
    "ticket.creation" => :ticket_creation,
    "ticket.deletion" => :ticket_deletion,
    "ticket.propertyChange" => :ticket_property_change,
    "ticket.associationChange" => :ticket_association_change,
    "ticket.restore" => :ticket_restore,
    "ticket.merge" => :ticket_merge,
    "product.creation" => :product_creation,
    "product.deletion" => :product_deletion,
    "product.restore" => :product_restore,
    "product.merge" => :product_merge,
    "product.propertyChange" => :product_property_change,
    "line_item.creation" => :line_item_creation,
    "line_item.deletion" => :line_item_deletion,
    "line_item.associationChange" => :line_item_association_change,
    "line_item.restore" => :line_item_restore,
    "line_item.merge" => :line_item_merge,
    "line_item.propertyChange" => :line_item_property_change,
    "conversation.creation" => :conversation_creation,
    "conversation.deletion" => :conversation_deletion,
    "conversation.privacyDeletion" => :conversation_privacy_deletion,
    "conversation.propertyChange" => :conversation_property_change,
    "conversation.newMessage" => :conversation_new_message,
    "object.creation" => :object_creation,
    "object.deletion" => :object_deletion,
    "object.propertyChange" => :object_property_change,
    "object.associationChange" => :object_association_change,
    "object.restore" => :object_restore,
    "object.merge" => :object_merge
  }

  @identity_namespace "ash_hooks:hubspot:v1:"

  def signed_input(body, ctx) do
    ctx.method <>
      decode_request_uri(ctx.request_uri) <>
      body <> Signature.header(ctx, "x-hubspot-request-timestamp")
  end

  def decode_request_uri(uri) do
    replacements = [
      {"3A", ":"},
      {"2F", "/"},
      {"3F", "?"},
      {"40", "@"},
      {"21", "!"},
      {"24", "$"},
      {"27", "'"},
      {"28", "("},
      {"29", ")"},
      {"2A", "*"},
      {"2C", ","},
      {"3B", ";"}
    ]

    Enum.reduce(replacements, uri, fn {hex, char}, acc ->
      acc
      |> String.replace("%" <> hex, char)
      |> String.replace("%" <> String.downcase(hex), char)
    end)
  end

  @impl true
  def parse_event_type(payload) when is_list(payload) and payload != [] do
    case batch_types(payload, []) do
      {:ok, types} ->
        case Enum.uniq(types) do
          [single] -> {:ok, single}
          _mixed -> {:ok, :mixed}
        end

      {:error, _reason} = error ->
        error
    end
  end

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  @impl true
  def event_identity(events) when is_list(events) and events != [] do
    if Enum.all?(events, &identity_event?/1) do
      canonical_events =
        events
        |> Enum.map(fn event ->
          event
          |> Map.delete("attemptNumber")
          |> canonical_value()
          |> Jason.encode!()
        end)
        |> Enum.sort()

      identity =
        :crypto.hash(:sha256, @identity_namespace <> Jason.encode!(canonical_events))
        |> Base.encode16(case: :lower)

      {:ok, identity}
    else
      {:error, :malformed_payload}
    end
  end

  def event_identity(_payload), do: {:error, :malformed_payload}

  @spec batch_types(list(map()), [atom()]) :: {:ok, [atom()]} | {:error, atom()}
  defp batch_types([], types), do: {:ok, types}

  defp batch_types([%{"subscriptionType" => raw} | rest], types)
       when is_binary(raw) do
    case Map.fetch(@subscription_types, raw) do
      {:ok, type} -> batch_types(rest, [type | types])
      :error -> {:error, :unknown_event_type}
    end
  end

  defp batch_types([_non_event | _rest], _types), do: {:error, :malformed_payload}

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {key, canonical_value(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value

  defp identity_event?(%{"subscriptionType" => type}) when is_binary(type), do: true
  defp identity_event?(_event), do: false
end
```

#### Twilio

Replace `AshHooks.Provider.Twilio` with `MyApp.Webhooks.Messages`.
The auth token signs the exact public URL and sorted form names and unique
values. When `bodySHA256` is present, check the JSON body digest and sign only
the URL. Keep the decoder fallback for form and JSON deliveries, the generic
`:webhook` type, and the raw-body identity. There is no replay timestamp.

<!-- tested: upgrade-messages-provider -->
```elixir
defmodule MyApp.Webhooks.Messages do
  alias AshHooks.Provider.Signature

  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha1,
      signature: {:header, "x-twilio-signature"},
      encoding: :base64,
      signed_input: {__MODULE__, :signed_input}
    ]

  def signed_input(body, ctx) do
    {:ok, %URI{scheme: scheme, host: host, query: query}} = URI.new(ctx.request_uri)
    true = scheme in ["http", "https"] and is_binary(host) and host != ""

    case for({"bodySHA256", hash} <- URI.query_decoder(query || ""), do: hash) do
      [] ->
        suffix =
          body
          |> URI.query_decoder()
          |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map(fn {key, values} -> Enum.map(Enum.sort(Enum.uniq(values)), &[key, &1]) end)
          |> IO.iodata_to_binary()

        ctx.request_uri <> suffix

      [hash] ->
        :ok = Signature.compare(Base.encode16(:crypto.hash(:sha256, body), case: :lower), hash)
        ctx.request_uri
    end
  end

  @impl true
  def decode_payload(body), do: decode_payload(body, &Jason.decode/1)

  @impl true
  def decode_payload(body, decoder) do
    case decoder.(body) do
      {:ok, payload} when is_map(payload) or is_list(payload) -> {:ok, payload}
      _ -> AshHooks.Provider.decode_body(body, :form)
    end
  end
end
```

#### BigCommerce

Replace `AshHooks.Provider.BigCommerce` with `MyApp.Webhooks.CommerceEvents`.
Use the raw client-secret bytes, without `whsec_` or base64 key decoding. The
Standard Webhooks v1 signature covers `webhook-id.timestamp.body`. The default
window is 300 seconds in either direction; `replay_window_seconds` overrides it.
Keep the raw-body identity; do not switch the identity to `webhook-id`.

<!-- tested: upgrade-commerce-events-provider -->
```elixir
defmodule MyApp.Webhooks.CommerceEvents do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature:
        {:structured_header, "webhook-signature",
         signature_key: "v1", pair_separator: " ", key_value_separator: ","},
      encoding: :base64,
      timestamp: {:header, "webhook-timestamp"},
      signed_input: [{:header, "webhook-id"}, ".", :timestamp, ".", :body]
    ]
end
```

#### Magento2

Replace `AshHooks.Provider.Magento2` with `MyApp.Webhooks.CommerceRsa`.
Pin the public RSA verification key. The base64 signature authenticates the
base64 representation of the raw body. Keep the raw-body delivery identity.

<!-- tested: upgrade-commerce-rsa-provider -->
```elixir
defmodule MyApp.Webhooks.CommerceRsa do
  use AshHooks.Provider,
    verify: [
      algorithm: :rsa_pkcs1_sha256,
      signature: {:header, "x-adobe-commerce-webhook-signature"},
      signed_input: [{:base64, :body}]
    ]
end
```

#### Wix

Replace `AshHooks.Provider.Wix` with `MyApp.Webhooks.SiteTokens`.
Pin the public RSA key and keep the raw compact JWS body intact through
verification. This module calls the configured scheme directly to preserve the
former raw-JWS delivery identity. A generated `verify: [...]` JWS provider would
instead install a verified-payload identity, which requires legacy identity
adoption before resuming ingress. The scheme still checks `exp` and `nbf`.

<!-- tested: upgrade-site-tokens-provider -->
```elixir
defmodule MyApp.Webhooks.SiteTokens do
  use AshHooks.Provider
  alias AshHooks.Provider.{Event, Scheme}

  @scheme Scheme.new!(algorithm: :rsa_pkcs1_sha256, signature: :jws_body)

  @impl true
  def signature_source, do: :body

  @impl true
  def verify_signature(body, ctx, key), do: Scheme.verify(body, ctx, key, @scheme)

  @impl true
  def decode_payload(body), do: Scheme.decode_payload(body, @scheme)

  @impl true
  def decode_payload(body, decoder), do: Scheme.decode_payload(body, @scheme, decoder)

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse

  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
```

#### EasyPost

Replace `AshHooks.Provider.EasyPost` with `MyApp.Webhooks.ParcelEvents`.
Keep both configurations: v1 normalizes byte secrets with Unicode NFKD and signs
the raw body; v2 uses the raw secret and signs the RFC 2822 timestamp, method,
encoded path without the query, and body. Supply the exact signed method and
request URI. A present v2 header selects v2 even if malformed; never fall back
to v1 after a v2 failure. The v2 recipe has a 60-second symmetric replay window.
Keep the generic event type and raw-body identity for both versions. Since v1
has no timestamp, leave declaration-level `replay_window_seconds` unset.

<!-- tested: upgrade-parcel-events-provider -->
```elixir
defmodule MyApp.Webhooks.ParcelEvents do
  alias AshHooks.Provider.Scheme

  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-hmac-signature", prefix: "hmac-sha256-hex="}
    ]

  @impl true
  def verify_signature(body, ctx, key) do
    if Enum.any?(ctx.headers, fn {name, _} -> String.downcase(name) == "x-hmac-signature-v2" end) do
      Scheme.verify(body, ctx, key,
        algorithm: :hmac_sha256,
        signature: {:header, "x-hmac-signature-v2", prefix: "hmac-sha256-hex="},
        encoding: :hex_any,
        signed_input: [{:header, "x-timestamp"}, :method, :path, :body],
        timestamp: {__MODULE__, :rfc2822_timestamp},
        tolerance_seconds: 60
      )
    else
      super(body, ctx, :unicode.characters_to_nfkd_binary(key))
    end
  end

  def rfc2822_timestamp(_, ctx) do
    # httpd_util uses numeric offsets and returns UTC seconds since year zero.
    timestamp = AshHooks.Provider.Signature.header(ctx, "x-timestamp")

    case :httpd_util.convert_request_date(String.to_charlist(timestamp)) do
      {{_, _, _}, {_, _, _}} = datetime ->
        {:ok, :calendar.datetime_to_gregorian_seconds(datetime) - 62_167_219_200}

      _ ->
        :error
    end
  end
end
```

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
  this release (the extension itself is new in 2.2.0).
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
  stays sound). Resources without the columns keep the ceiling semantics
  from versions before 2.2.0.

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
2. Upgrade to `{:ash_hooks, ">= 2.0.1 and < 3.0.0"}` with Ash `>= 3.34.3 and < 4.0.0-0`. Generate
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
6. Deploy all 2.0.1 application nodes and workers together. Enable the periodic
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

{:ok, plan} =
  AshHooks.Ingress.plan_legacy_identity_adoption(MyApp.InboundLedger, :existing_source, opts)

# Review plan.audit; resolve every item in plan.unresolved and plan.conflicts.
{:ok, applied} =
  AshHooks.Ingress.adopt_legacy_identity(
    MyApp.InboundLedger,
    :existing_source,
    Keyword.put(opts, :quiesced?, true)
  )
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
   row; it does not guarantee one network side effect. Version 2.0.1 adds durable
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
2. **String and integer tenants are supported job-args shapes.** The worker
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
ash_hooks on Elixir >= 1.17.0 and < 1.20.0 get a hard resolver error at deps
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
and then fail the delivery write; under Ash >= 3.33.0 `:codepoints` counting,
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

Every Ash version supported by ash_hooks requires this configuration
before compiling resources. ash_hooks writes no `:ash` configuration for you. Set it
in your application's `config/config.exs`:

<!-- tested: upgrade-string-config-in-application -->
```elixir
# Recommended: counts unicode codepoints, so max_length bounds value
# size and validation matches how SQL data layers count.
config :ash, default_string_length_count: :codepoints

# Keeps behavior from Ash versions before 3.33.0: graphemes are counted when validating in
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
option in `AshHooks.Http.Bounded.request/5` and `AshHooks.Http.Httpc.request/5`, passed through
`AshHooks.Worker`'s `:http_opts` contract. Private CA bundles can be compile-time
literals or `{m, f, a}` values resolved per perform.

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

The `~> 1.0` constraint excludes versions >= 2.0.0. Deprecations remain supported
for at least two minor releases. Safety corrections may change defective
behavior in a patch release.
