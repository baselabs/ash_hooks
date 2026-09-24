# Multi-tenant adoption checklist

ash_hooks 1.2+ supports Ash attribute multitenancy: every dispatch, ingest,
delivery run, sweep, and reconciliation threads an explicit tenant, and the
package fails closed with a named error when a multitenant resource is
touched without one. This checklist walks one app — two tenants or two
thousand — through the same steps. The reasoning behind the floor is
[ADR-0011](https://github.com/baselabs/ash_hooks/tree/main/docs/adr).

## The contract

Declare the SAME attribute strategy on the resources a given operation
touches — for the full outbound machine that is your Subscription, your
Endpoint, and your OutboundDelivery ledger; for inbound, your
InboundDelivery ledger. (An inbound-only app declares tenancy on its
ledger alone — each operation verifies the set it actually reads.)

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

Two declarations are rejected outright with `{:error, :tenancy_mismatch}`:

- `global?: true` — it looks consistent while silently allowing
  tenant-less reads, which would disable every guarantee below.
- non-`:attribute` strategies — attribute is the only strategy that
  works across every data layer the package supports.

## The ordered steps

**0. Drain in-flight Oban jobs from the 1.1.x shape** (skip if you have
no queued deliveries). The moment your resources declare multitenancy,
jobs enqueued by the old version — whose args carry no tenant — start
failing closed with `{:error, :tenant_required}` when they run. That is
the correct, safe behavior, but it is noisy: drain or complete the old
queue BEFORE deploying the version whose resources declare tenancy.

**1. Add the tenant columns, then backfill them.** First the columns
(in the adopter's migration):

```sql
ALTER TABLE webhook_endpoints ADD COLUMN org_id TEXT;
-- ...likewise for webhook_subscriptions, inbound_deliveries,
--    outbound_deliveries
```

Then backfill — every legacy row must get its tenant value:

```sql
-- your mapping from existing rows to their owning tenant
UPDATE webhook_endpoints SET org_id = <derived per row>;
UPDATE webhook_subscriptions SET org_id = <derived per row>;
UPDATE inbound_deliveries SET org_id = <derived per row>;
UPDATE outbound_deliveries SET org_id = <derived per row>;
```

Verify zero NULL tenants remain:

```sql
-- must return 0 for every table
SELECT COUNT(*) FROM outbound_deliveries WHERE org_id IS NULL;
```

A NULL-tenant row is a quiet trap: the unique identities become
tenant-scoped in step 2, and NULL never equals a tenant value — so a new
delivery creates a PARALLEL row instead of matching the old one, the
enqueue then collides with the historical completed job, and the new row
sits at `:pending` forever. NULL-tenant rows are also invisible to every
tenant-scoped sweep. Backfill before proceeding; the count above is the
gate.

**2. Regenerate migrations so the unique identities include the tenant.**
The unique identities (`unique_delivery` on endpoint+event,
`unique_ingest` on provider+external id + scope) become tenant-prefixed
unique indexes — run your `mix ash.codegen` / migration generator after
adding the declarations. Dedup is per-tenant by construction from here:
the same provider event id in two tenants is two rows, both processed.

**3. Deploy, and thread the tenant through your call sites.**

```elixir
# outbound — every call
AshHooks.dispatch(Order, :order_paid, event, tenant: org.id)

# inbound — the tenant rides the request context
AshHooks.Ingress.ingest(WebhookLedger, :stripe, raw_body, %{signature: sig, tenant: org.id})

# the worker (unchanged) — the enqueue serializes the row's tenant into
# job args; Delivery.run/2 recovers it after any restart
```

**4. Adopt the per-tenant operations surface.**

- Sweeps are per-tenant: `reap/2` and both `prune/2`s take `:tenant`;
  `AshHooks.reap_all/2` and `AshHooks.prune_all/2` sweep a list of
  tenants sequentially — one tenant's failure never stops the others —
  and return each tenant's result plus a total:
  `{:ok, %{results: %{"org_a" => {:ok, 3}, ...}, total: 3}}`.
- Reconciliation of rows stranded at `:pending` by a crash between the
  row write and the enqueue:
  `AshHooks.reconcile_pending(Order, :order_paid, tenant: org.id,
  enqueue: {MyWorker, :enqueue})`. The delivery resource needs
  `timestamps()` (`inserted_at` drives the staleness cutoff — the
  default of five minutes is right for almost everyone). Concurrent
  reconcilers never double-claim a row; note that the enqueue callback
  receives the event reconstructed from the row (id, type, payload —
  its metadata map is empty), so write custom callbacks accordingly.
- Tenant-aware secrets (all optional): the worker macro's
  `tenant_aware_secrets: true` (resolver becomes `f(ref, tenant)`), the
  inbound `secret fn tenant -> {:ok, secret} end`, and the provider
  `webhook_signing_secret(connection, tenant)` override for
  per-Organization connection custody.

## The isolation guarantees (what you may rely on)

- A dispatch for tenant A cannot create a delivery row for tenant B's
  endpoint; a subscription pointing at another tenant's endpoint_id
  resolves to not-found and is skipped; the 410-disable cannot be aimed
  cross-tenant.
- The inbound dedup identity is per-tenant; the claim fence, marks,
  renewal, and redaction are per-tenant.
- A tenant-less call against a multitenant set returns
  `{:error, :tenant_required}` before any data access.
- Workers recover full tenant context from job args alone (string
  tenants are the supported shape; a custom `parse_attribute` pairs
  with `tenant_from_attribute`, which the worker inverts through).
- Reconciliation claims each stranded row at most once per run. One
  caveat across mechanisms: a re-dispatch of a reconciled event claims
  the row again through the ordinary repair path and may enqueue it a
  second time — with the package's Oban worker this is deduplicated by
  job uniqueness; if you supply your OWN enqueue function, it must
  tolerate being called twice for the same row.

## Single-tenant apps

Change nothing. No tenant passed, no tenant threaded: behavior is
identical to 1.1.x — the library's own test suite runs entirely over
tenant-less fixtures in both versions.
