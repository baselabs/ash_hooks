# Multi-tenant adoption checklist

ash_hooks supports Ash attribute multitenancy: pass an explicit tenant to dispatch, ingest,
delivery runs, sweeps, and reconciliation. Tenant validation checks the resource
set touched by each operation, including the outbox and optional logs.
`AshHooks.Tenancy` documents the supported tenancy strategies and validation
rules.

## The contract

Declare compatible attribute tenancy on every resource an operation touches:
subscriptions, endpoints, outbound deliveries, outboxes, enabled attempt and
event logs, inbound ledgers, inbound sources, and custody registries. Entry points supply
every resource they read or write to `AshHooks.Tenancy.resolve/2`. Event-log replay also forwards
the tenant when it rearms an existing terminal delivery.

Add a non-nullable tenant attribute (for example `:org_id`) and declare
`multitenancy` with `strategy :attribute` and `attribute :org_id` on each resource.
The [Livebook](../livebooks/get-started.livemd) executes complete multitenant
resource declarations and calls.

Two declarations are rejected outright with `{:error, :tenancy_mismatch}`:

- `global?: true`: it looks consistent while silently allowing
  tenant-less reads, which would disable every guarantee below.
- non-`:attribute` strategies: attribute is the only strategy that
  works across every data layer the package supports.

## The ordered steps

If you are also upgrading from a version >= 1.0.0 and < 2.0.0 to 3.8.0, complete
the intervening schema and declaration/route migrations in
[UPGRADING](../../UPGRADING.md) before enabling the new runtime.

**0. Drain Oban jobs created before 1.2.0** (skip if you have
no queued deliveries). The moment your resources declare multitenancy,
jobs enqueued by the old version, whose args carry no tenant, start
failing closed with `{:error, :tenant_required}` when they run. That is
the correct, safe behavior, but it is noisy: drain or complete the old
queue BEFORE deploying the version whose resources declare tenancy.

**1. Add the tenant columns, then backfill them.** The following four tables
are examples. Apply the same column, backfill, constraint, and isolation checks
to every package resource your application uses, including outboxes, optional
attempt logs, event logs, inbound sources, and custody registries. First the columns
(in the adopter's migration):

<!-- tested: tenancy-add-columns -->
```sql
ALTER TABLE webhook_endpoints ADD COLUMN org_id TEXT;
ALTER TABLE webhook_subscriptions ADD COLUMN org_id TEXT;
ALTER TABLE inbound_deliveries ADD COLUMN org_id TEXT;
ALTER TABLE outbound_deliveries ADD COLUMN org_id TEXT;
```

Then backfill: every legacy row must get its tenant value. This example assumes
the application's authoritative `account_tenants(account_id, org_id)` mapping
contains exactly one non-NULL tenant for every legacy account. Endpoints and
inbound deliveries already carry `account_id`; subscriptions and outbound
deliveries carry `endpoint_id`, referencing `webhook_endpoints.id`. Populate
and validate that mapping from the application's ownership records first.
Derive each child row's tenant from its endpoint, rather than independently
assigning a tenant that could disagree with that endpoint:

<!-- tested: tenancy-backfill -->
```sql
UPDATE webhook_endpoints
SET org_id = (
  SELECT account_tenants.org_id
  FROM account_tenants
  WHERE account_tenants.account_id = webhook_endpoints.account_id
);

UPDATE inbound_deliveries
SET org_id = (
  SELECT account_tenants.org_id
  FROM account_tenants
  WHERE account_tenants.account_id = inbound_deliveries.account_id
);

UPDATE webhook_subscriptions
SET org_id = (
  SELECT webhook_endpoints.org_id
  FROM webhook_endpoints
  WHERE webhook_endpoints.id = webhook_subscriptions.endpoint_id
);

UPDATE outbound_deliveries
SET org_id = (
  SELECT webhook_endpoints.org_id
  FROM webhook_endpoints
  WHERE webhook_endpoints.id = outbound_deliveries.endpoint_id
);
```

Verify zero NULL tenants remain. All four result rows must be 0; a missing
account mapping or endpoint reference leaves NULL and prevents proceeding:

<!-- tested: tenancy-null-count -->
```sql
SELECT COUNT(*) FROM webhook_endpoints WHERE org_id IS NULL
UNION ALL
SELECT COUNT(*) FROM webhook_subscriptions WHERE org_id IS NULL
UNION ALL
SELECT COUNT(*) FROM inbound_deliveries WHERE org_id IS NULL
UNION ALL
SELECT COUNT(*) FROM outbound_deliveries WHERE org_id IS NULL;
```

A NULL-tenant row is a quiet trap: the unique identities become
tenant-scoped in step 2, and NULL never equals a tenant value, so a new
delivery creates a separate row instead of matching the old one and may repeat
its network effect. NULL-tenant rows are also invisible to every
tenant-scoped sweep. Backfill before proceeding; the count above is the
gate.

**2. Regenerate migrations so the unique identities include the tenant.**
The unique identities (`unique_delivery` on endpoint+event,
`unique_ingest` on provider+external id + scope) become tenant-prefixed
unique indexes; run your `mix ash.codegen` / migration generator after
adding the declarations. Dedup is per-tenant by construction from here:
the same provider event id in two tenants is two rows, both processed.

**3. Deploy, and thread the tenant through your call sites.**

Pass `tenant: tenant` to `AshHooks.dispatch/4` and include `tenant: tenant` in
the request context passed to `AshHooks.Ingress.ingest/4`. The generated worker
serializes the tenant from the row into job args and restores it on execution.

**4. Adopt the per-tenant operations surface.**

- Sweeps are per-tenant: `reap/2` and both `prune/2`s take `:tenant`;
  `AshHooks.reap_all/2` and `AshHooks.prune_all/2` sweep a list of
  tenants sequentially (one tenant's failure never stops the others)
  and return each tenant's result plus a total:
  `{:ok, %{results: %{"org_a" => {:ok, 3}, ...}, total: 3}}`.
- Reconciliation of stale pending rows, enqueue failures, due retries, expired
  sends, and pending endpoint disables:
  `AshHooks.reconcile_pending(Order, :order_paid, tenant: org.id,
  enqueue: {MyWorker, :enqueue})`. The delivery resource needs
  `timestamps()` (`inserted_at` drives the staleness cutoff; the
  default is five minutes). Use the same declaration and durable queue route.
  Concurrent reconcilers use separate expiring enqueue claims; the enqueue callback
  receives the event reconstructed from the row (id, type, and payload)
  with an empty metadata map, so write custom callbacks accordingly.
- Tenant-aware secrets (all optional): the worker macro's
  `tenant_aware_secrets: true` (resolver becomes `f(ref, tenant)`), the
  inbound `secret fn tenant -> {:ok, secret} end`, and the provider
  `webhook_signing_secret(connection, tenant)` override for
  per-tenant signing-secret resolution.

## Canonical custody tenants and row security

For a stored row, call `AshHooks.Tenancy.from_row/1` before reusing its tenant in
entry-point options. It applies the resource's `tenant_from_attribute` inverse;
reading the raw attribute bypasses that inverse and may apply a nonidentity
parser twice. Custody then calls `AshHooks.Custody.canonical_tenant/3` with the
owner resource, following its create-path tenant conversion and constrained cast.
UUID and UUIDv7 values normalize case, integers use decimal text, strings stay
exact UTF-8, and ci_strings normalize case. Non-multitenant owners use `nil`.
Invalid values return `:invalid_tenant`; unsupported types return
`:unsupported_tenant_type`. `tenant_type_supported?/2` checks type coverage.

Other attribute types require a `custody_tenant_key {module, function, args}`
option on the endpoint or inbound source. Its cast-value callback must return
equal UTF-8 binaries whenever the database treats two values as equal. The
registry stores this canonical custody identity separately from its database
tenant and uses it after owner deletion. See [the key guide](key-custody.md).

Source records use `AshHooks.Ingress.resolve_source/3` with both tenant and scope.
It validates matching source/ledger tenancy and casts all scope fields before a
source read. Reuse its result through the same request's `:resolved_source`
ingest context. Schedule endpoint/source expiry, registry sweeps, registry
failure recovery, and alias adoption per tenant, as well as delivery retention.

Package database work uses bounded tenant transactions, and reads inside each
phase use the write repository on AshPostgres and transactional AshSqlite.
PostgreSQL hosts bind transaction-local row-security settings in the repository's
`on_transaction_begin/1`. Secure package tables and both Oban tables, and bind
an enclosing host transaction to the same tenant. Use an insert-only Oban
instance on the runtime ledger repository and a separate engine-role instance
for queues and maintenance, sharing the prefix and PostgreSQL notifier. The
[row-security guide](row-security.md) provides exact role, grant, policy, and
supervision examples;
SQLite tenant filtering does not exercise PostgreSQL row security.

## Physical database bindings

A physical database binding selects Ecto repository instances. The explicit
`:tenant` option still selects rows inside that database for resources that
declare attribute multitenancy. Install the physical binding in the calling
process before using the outbound entry points.

For example, start two instances of the same repo under `MyApp.LiveRepo` and
`MyApp.TestRepo`, with each instance configured for its own database. Migrate
the webhook resources and Oban tables in each database. Start one Oban
instance per database with the shared repo module and its own
`:get_dynamic_repo` callback. This wraps Oban's own repo calls, including
polling and staging outside a request process. Job callbacks establish their
own repository binding.

In Oban testing mode, bind the repository in the process that calls
`Oban.start_link/1` so the startup migration check queries the intended database.

<!-- not-run: This example requires two supervised repository and Oban instances in a host application. -->
```elixir
defmodule MyApp.HooksBinding do
  @behaviour AshHooks.Binding

  @impl true
  def current do
    case MyApp.Repo.get_dynamic_repo() do
      MyApp.LiveRepo -> "live"
      MyApp.TestRepo -> "test"
    end
  end

  @impl true
  def bind("live") do
    MyApp.Repo.put_dynamic_repo(MyApp.LiveRepo)
    :ok
  end

  def bind("test") do
    MyApp.Repo.put_dynamic_repo(MyApp.TestRepo)
    :ok
  end

  def bind(_name), do: {:error, :unknown_binding}

  @impl true
  def oban("live"), do: MyApp.LiveOban
  def oban("test"), do: MyApp.TestOban
end

defmodule MyApp.WebhookWorker do
  use AshHooks.Worker,
    deliveries: MyApp.OutboundDelivery,
    endpoints: MyApp.WebhookEndpoint,
    outbox: MyApp.WebhookPublication,
    binding: MyApp.HooksBinding,
    queue: :webhooks
end

children = [
  {Oban,
   name: MyApp.LiveOban,
   repo: MyApp.Repo,
   queues: [webhooks: 10],
   get_dynamic_repo: fn -> MyApp.LiveRepo end},
  {Oban,
   name: MyApp.TestOban,
   repo: MyApp.Repo,
   queues: [webhooks: 10],
   get_dynamic_repo: fn -> MyApp.TestRepo end}
]
```

Call `MyApp.HooksBinding.bind("live")` in a process that publishes to the live
database. Configure `bind/1` to select every repo module used by the job's
resources and host callbacks, including a separate signing-key store when used.
Derive `current/0` from the selected repositories. Keep names stable while
queued jobs refer to them. A job with an unknown name is canceled with
`:unknown_binding`.

### Maintenance jobs

When scheduling publication sweeps, delivery reconciliation, or reapers with
Oban Cron or another plugin, schedule each job once per physical binding.
Call `bind/1` from the host worker's `perform/1` before calling AshHooks. For
multitenant resources, run each maintenance operation for every tenant in
that binding.

<!-- not-run: This Cron worker requires a host binding, declaration, and webhook resources. -->
```elixir
defmodule MyApp.WebhookMaintenance do
  use Oban.Worker, queue: :webhooks

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"binding" => name}}) do
    with :ok <- MyApp.HooksBinding.bind(name),
         {:ok, _} <- AshHooks.fanout_pending(MyApp.WebhookPublication, 100),
         {:ok, _} <-
           AshHooks.reconcile_pending(MyApp.Order, :paid,
             enqueue: {MyApp.WebhookWorker, :enqueue}
           ),
         {:ok, _} <- AshHooks.KeyRegistry.sweep(MyApp.WebhookKeyRegistry) do
      :ok
    else
      {:error, :unknown_binding} -> {:cancel, :unknown_binding}
      {:error, _} = error -> error
    end
  end
end

# In each binding's Oban instance, set the corresponding name in the Cron entry.
live_cron =
  {Oban.Plugins.Cron,
   crontab: [
     {"*/5 * * * *", MyApp.WebhookMaintenance, args: %{binding: "live"}}
   ]}
```

Select the same repositories before sending returned publication notifications.
For forced row security, retain the tenant and engine role configuration from
the [row-security guide](row-security.md) in each database.

## The isolation guarantees (what you may rely on)

- A dispatch for tenant A cannot create a delivery row for tenant B's
  endpoint; a subscription pointing at another tenant's endpoint_id
  resolves to not-found and is skipped; the 410-disable cannot be aimed
  cross-tenant.
- The inbound dedup identity is per-tenant; the claim fence, marks,
  renewal, and redaction are per-tenant.
- A tenant-less call against a multitenant set returns
  `{:error, :tenant_required}` before any data access.
- Multitenant jobs store the row's tenant in `args["tenant"]`. The tenant must
  survive Oban's JSON encoding unchanged: strings (UUIDs and slugs) and integers
  do; an atom arrives as a string. Pair a custom `parse_attribute` with
  `tenant_from_attribute` so the stored attribute and job tenant round-trip.
  Use `args->>'tenant'`, the tenant's text form, in the runtime role's job
  policies. The runtime role can select and insert only its tenant's jobs;
  it cannot update jobs or access `oban_peers`. The separate engine role needs
  policies over all rows of `oban_jobs` and `oban_peers`, with row security
  enabled and forced on both tables. A tenant-only policy hides queued jobs
  from Oban's unbound engine.
- Recovery is fenced to the row's declaration, route, tenant, and enqueue token.
  A crash after queue admission can still invoke a custom enqueue callback again;
  make that callback idempotent. The generated Oban worker requires a persisted
  matching runnable job before reporting successful admission.

## Single-tenant apps

Leave multitenancy undeclared and omit `:tenant`. The same entry points work
with a single-tenant ledger; the schema upgrade introduced in 2.0.1 still applies.
