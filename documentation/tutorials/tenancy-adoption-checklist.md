# Multi-tenant adoption checklist

ash_hooks 1.2+ supports Ash attribute multitenancy: every dispatch, ingest,
delivery run, sweep, and reconciliation threads an explicit tenant, and the
package fails closed (named errors) when a multitenant resource is touched
without one. This is the universal two-tenant adoption checklist — the same
steps for any app. (Design: ADR-0011.)

## The contract

Declare the SAME attribute strategy on all four resources — your
Subscription, your Endpoint, your InboundDelivery ledger, your
OutboundDelivery ledger:

```elixir
attributes do
  # ...the extension's injected fields...
  attribute :org_id, :string, allow_nil?: false
end

multitenancy do
  strategy :attribute
  attribute :org_id
end
```

`global?: true` is rejected by the package (`{:error, :tenancy_mismatch}`):
it passes a same-attribute consistency check while silently permitting
tenant-less reads — disabling every fail-closed guarantee. Non-`:attribute`
strategies are rejected for the same reason (portability): attribute is the
only strategy the package supports across its data layers.

## The ordered steps

**1. Backfill the tenant attribute onto existing rows.** In the adopter's
migration, before enabling multitenant dispatch:

```sql
-- every legacy row must get its tenant value
UPDATE webhook_endpoints SET org_id = <derived per row>;
UPDATE webhook_subscriptions SET org_id = <derived per row>;
UPDATE inbound_deliveries SET org_id = <derived per row>;
UPDATE outbound_deliveries SET org_id = <derived per row>;
```

Verify zero NULL tenants remain (the package's own consistency check plus
this count is your verification):

```sql
-- must return 0 for every table
SELECT COUNT(*) FROM outbound_deliveries WHERE org_id IS NULL;
```

A NULL-tenant legacy row forms a shadow partition: new tenant-bearing upserts
create PARALLEL rows (upsert conflict keys include the tenant attribute;
NULL ≠ value), the enqueue then conflicts with the historical completed job,
and the new row strands at `:pending` unreconcilably. NULL-tenant rows are
also unreachable by any tenant-scoped prune and immortal against a global
sweep (TenantRequired). Backfill is step one for a reason.

**2. Regenerate migrations so identity indexes include the tenant.** The
unique identities (`unique_delivery` on endpoint+event, `unique_ingest` on
provider+external id + scope) become tenant-prefixed unique indexes. With
`mix ash.codegen` / the migration generator, changing a resource's
multitenancy rewrites the identity indexes. Dedup is per-tenant by
construction after this step — the same provider event id in two tenants is
two rows, both processed.

**3. Only then enable multitenant dispatch.** Thread `tenant:` through your
call sites:

```elixir
# outbound — every call
AshHooks.dispatch(Order, :order_paid, event, tenant: org.id)

# inbound — the tenant rides the ctx
AshHooks.Ingress.ingest(WebhookLedger, :stripe, raw_body, %{signature: sig, tenant: org.id})

# the worker (unchanged) — the enqueue serializes the row's tenant into job
# args; Delivery.run/2 recovers it after any restart
```

**4. Drain pre-tenancy Oban jobs before serving multitenant dispatch** (only
if you have in-flight 1.1.x jobs). Pre-tenancy args carry no tenant and fail
closed against multitenant resources — correct, but noisy. Drain first.

**5. Adopt the per-tenant operations surface.**

- Sweeps are per-tenant: `reap/2`, both `prune/2`s take `:tenant`; the
  `AshHooks.reap_all/2` / `AshHooks.prune_all/2` sugar maps over your tenant
  enumeration sequentially (per-tenant error isolation, `+%{results | total}`
  totals).
- Reconciliation of stranded `:pending` rows:
  `AshHooks.reconcile_pending(resource, name, older_than: cutoff, tenant: org.id,
  enqueue: {MyWorker, :enqueue})` — leave the default 5-minute cutoff.
- Tenant-aware secrets (all optional): the worker macro's
  `tenant_aware_secrets: true` (resolver becomes `f(ref, tenant)`), the
  inbound `secret fn tenant -> {:ok, secret} end`, and the provider
  `webhook_signing_secret(connection, tenant)` override for
  Organization × connection custody.

## The isolation guarantees (what you may rely on)

- A dispatch for tenant A cannot create a delivery row for tenant B's
  endpoint; a subscription pointing at another tenant's endpoint_id resolves
  NotFound and is skipped; the 410-disable cannot be aimed cross-tenant.
- The inbound dedup identity is per-tenant; the claim fence, marks, renewal,
  and redaction are per-tenant.
- A tenant-less call against a multitenant set returns
  `{:error, :tenant_required}` before any data access — on every entry
  family, including the sweep heads that would otherwise crash.
- Workers recover full tenant context from job args alone (string tenants
  are the supported shape; a custom `parse_attribute` pairs with
  `tenant_from_attribute`, which the worker inverts through).

## Single-tenant apps

Change nothing. No tenant passed, no tenant threaded: behavior is
byte-identical to 1.1.x (the full pre-existing test suite runs unchanged over
tenant-less fixtures — that is a shipped proof, not a claim).
