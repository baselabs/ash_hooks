# Row-level security

AshHooks opens a bounded Ash transaction for each database phase. It converts
the supplied tenant through `Ash.ToTenant` for every resource in that phase and
places the agreed key in the transaction reason. The host repository binds that
key to its PostgreSQL policies. HTTP requests, inbound handlers, custody
callbacks, and retry sleeps run outside the package's phases.

Every row-secured package resource must declare compatible Ash attribute
multitenancy. Package entry points refuse context tenancy. A forced table
without Ash multitenancy is unsupported: the transaction's tenant is the only
binding input. Policies that need more information must derive it from that
tenant in the host binding. Application authorization remains the host's
responsibility; these machine operations use `authorize?: false`.

## Bind the outermost transaction

Add a transaction-begin callback to the repository used by the package
resources. This example targets PostgreSQL 16 or later; declare your
application's actual minimum version. Configure and supervise the repo as
usual. The setting name belongs to the application and must match its policies.

<!-- tested: row-security-repo-binding -->
```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo,
    otp_app: :my_app,
    warn_on_missing_ash_functions?: false

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @impl true
  def on_transaction_begin(reason) do
    case reason[:tenant] do
      nil ->
        :ok

      tenant ->
        query!("SELECT set_config('my_app.tenant', $1, true)", [
          to_string(tenant_key(reason, tenant))
        ])

        :ok
    end
  end

  defp tenant_key(%{metadata: %{resource: resource}}, tenant),
    do: Ash.ToTenant.to_tenant(tenant, resource)

  defp tenant_key(_reason, tenant), do: tenant
end
```

`set_config(name, value, true)` makes the setting transaction-local. Both commit
and rollback clear it before the pooled connection is reused. Read only
`reason[:tenant]`; neither a process dictionary nor a worker wrapper supplies
the tenant.

An action's transaction reason carries the tenant as the caller passed it and
names the action's resource, so the callback converts it with `Ash.ToTenant`
for that resource. An `Ash.transact/3` reason names no resource, so its tenant
must already be the key. Package phases pass the key: each phase converts the
operation's tenant with every resource it touches and refuses with
`{:error, :tenancy_mismatch}` when they disagree. Pass the key to your own
`Ash.transact/3` calls too.

A package phase inside a host transaction joins that transaction and does not
call the hook again. Bind the outermost transaction with the same tenant, for
example through `Ash.transact(resources, callback, tenant: key)`. Do not mix
tenants in that transaction. A raw repository transaction does not invoke
AshPostgres's Ash transaction hook by itself.

`AshHooks.Delivery.run/2` and `test_send/2` return
`{:error, :inside_transaction}` when the delivery resource is already in a
transaction, before starting a process or accessing the database. Their
monitored child preserves the attempt deadline and opens its own tenant phases.
An inline enqueue callback that invokes the driver inside a host transaction
therefore makes dispatch report `:enqueue_failed`, leaving the delivery
`:pending` for recovery. Enqueue the job and let its worker perform after commit.
Key issuance and registry sweeps also retain their transaction refusals.

## Alarm on missing work

A row hidden by row security looks absent. The fanout worker cancels its Oban
job with `:publication_missing`; the delivery worker cancels with
`:delivery_missing`. Fanout of a failed publication cancels with
`:publication_failed`. Invalid fanout arguments cancel with `:invalid_event`
or `:unknown_source`, and invalid or absent delivery identity cancels with
`:invalid_delivery_identity`. These jobs end `cancelled`, without an Oban retry.

Alarm on Oban cancellations, `[:ash_hooks, :outbox, :claim]` outcomes
`:missing` and `:failed`, and `[:ash_hooks, :delivery, :missing]`. Claim events
also expose already-done rows and storage errors. Events carry only the
requested identity and classified outcome, never tenant values, payloads, or
metadata contents. Bind the tenant in the repository's transaction-begin
callback above for every tenant-bearing database phase, including the delivery
driver's spawned phases. The package cannot detect a missing policy binding.

Fanout completes its trigger for `:busy`, `:stale`, or a persisted pending retry.
It does not re-enqueue a job. Schedule `AshHooks.fanout_pending/3` for every
tenant even with a trigger: without the sweep, these publications stay pending.
Use outbox claim and result telemetry to observe them. Delivery retries use
Oban snoozes or retries of the same job, with `AshHooks.reconcile_pending/3`
recovering stranded rows under the host's per-tenant schedule.

## Secure tables and jobs

Generate the ordinary resource migrations first. Enable and force row-level
security on every package table your application uses: endpoints,
subscriptions, deliveries, attempts, event logs, inbound ledgers, inbound
sources, and custody registries. The application role must neither own these tables nor have
superuser or `BYPASSRLS` privileges.

For a text tenant attribute named `tenant_id`, both the policy's `USING` and
`WITH CHECK` expressions can use
`tenant_id = current_setting('my_app.tenant', true)`. Apply the policy to every
operation the application role needs. Cast according to the actual tenant
column type. Enable `FORCE ROW LEVEL SECURITY` as well as `ENABLE ROW LEVEL
SECURITY`, and verify access through the application role with no binding.

The ledger column must store the bound tenant key, or its policy must compare
against the parsed key. For example, if `parse_attribute` uppercases the tenant
and `tenant_from_attribute` lowercases it, both ledger expressions use
`tenant_id = upper(current_setting('my_app.tenant', true))`. Integer columns
compare against `nullif(current_setting('my_app.tenant', true), '')::bigint`. Job policies
still compare the unparsed text key because job args store the recovered tenant.

Multitenant jobs store the row's tenant in `args["tenant"]`. The tenant must
survive Oban's JSON encoding unchanged: strings (UUIDs and slugs) and integers
do; an atom arrives as a string. Pair a custom `parse_attribute` with
`tenant_from_attribute` so the stored attribute and job tenant round-trip.
Use `args->>'tenant'`, the tenant's text form, for application access to jobs.

### Separate insertion from queue execution

Oban's engine fetches, stages, rescues, prunes, and transitions jobs without a
tenant binding. Its database peer also reads and writes `oban_peers`, which has
no tenant column. A tenant-only job policy hides runnable jobs from the engine.
Use two database roles and two Oban instances sharing one database and prefix.

Create login roles as a database administrator. Provision their credentials
through the application's secret store. Neither role may own either table,
inherit the table owner's privileges, be a superuser, or bypass row security.
Keep migrations on a separate owner connection. If the runtime role already
exists, apply these restrictions to it instead of creating it again.

<!-- tested: row-security-oban-roles -->
```sql
CREATE ROLE my_app_runtime LOGIN NOSUPERUSER NOBYPASSRLS;
CREATE ROLE my_app_oban_engine LOGIN NOSUPERUSER NOBYPASSRLS;
```

Run Oban's migrations in the `webhook_jobs` prefix using the owner connection,
then apply the following SQL as that owner. This prefix is dedicated to AshHooks
jobs; other host jobs use a separate prefix or instance. Replace the example prefix, role
names, and setting name consistently. Remove any older policies and grants
that would widen these permissions; permissive policies combine with OR.

<!-- tested: row-security-oban-policies -->
```sql
REVOKE ALL ON webhook_jobs.oban_jobs, webhook_jobs.oban_peers FROM PUBLIC;
GRANT USAGE ON SCHEMA webhook_jobs TO my_app_runtime, my_app_oban_engine;
GRANT USAGE ON SEQUENCE webhook_jobs.oban_jobs_id_seq
  TO my_app_runtime, my_app_oban_engine;
GRANT SELECT, INSERT ON webhook_jobs.oban_jobs TO my_app_runtime;
GRANT SELECT, INSERT, UPDATE, DELETE
  ON webhook_jobs.oban_jobs, webhook_jobs.oban_peers TO my_app_oban_engine;

ALTER TABLE webhook_jobs.oban_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_jobs.oban_jobs FORCE ROW LEVEL SECURITY;
ALTER TABLE webhook_jobs.oban_peers ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_jobs.oban_peers FORCE ROW LEVEL SECURITY;

CREATE POLICY runtime_job_read ON webhook_jobs.oban_jobs
  FOR SELECT TO my_app_runtime
  USING (args->>'tenant' = current_setting('my_app.tenant', true));
CREATE POLICY runtime_job_insert ON webhook_jobs.oban_jobs
  FOR INSERT TO my_app_runtime
  WITH CHECK (args->>'tenant' = current_setting('my_app.tenant', true));
CREATE POLICY engine_jobs ON webhook_jobs.oban_jobs
  FOR ALL TO my_app_oban_engine USING (true) WITH CHECK (true);
CREATE POLICY engine_peers ON webhook_jobs.oban_peers
  FOR ALL TO my_app_oban_engine USING (true) WITH CHECK (true);
```

The runtime role needs `SELECT` for Oban.Basic's unique-job lookup and
`INSERT ... RETURNING`, `INSERT` for admission, and sequence `USAGE` for IDs.
The unique path also takes a transaction-scoped advisory lock. The generated
worker does not request conflict replacement, so insertion needs no `UPDATE`.
Do not grant runtime `UPDATE`, `DELETE`, or access to `oban_peers`. A runtime
connection can read and insert only its bound tenant's jobs and cannot run the
queue engine. The engine role has policies over all job and peer rows; give it
no access to the package's tenant ledgers.

Configure `MyApp.Repo`, the ledger repository shown above, with runtime-role
credentials. Configure a separate repository with engine-role credentials and
the same database connection settings:

<!-- tested: row-security-oban-engine-repo -->
```elixir
defmodule MyApp.ObanEngineRepo do
  use Ecto.Repo,
    otp_app: :my_app,
    adapter: Ecto.Adapters.Postgres
end
```

Supervise both repositories before these Oban children. This configuration
uses Oban 2.24 or later. The application instance has no queues,
plugins, database peer, or stager. `plugins: false` alone does not disable the
stager. The engine instance owns queue execution and maintenance:

<!-- tested: row-security-oban-instances -->
```elixir
[
  {Oban,
   name: MyApp.Oban,
   repo: MyApp.Repo,
   prefix: "webhook_jobs",
   engine: Oban.Engines.Basic,
   notifier: Oban.Notifiers.Postgres,
   queues: false,
   plugins: false,
   peer: false,
   stager: false},
  {Oban,
   name: MyApp.ObanEngine,
   repo: MyApp.ObanEngineRepo,
   prefix: "webhook_jobs",
   engine: Oban.Engines.Basic,
   notifier: Oban.Notifiers.Postgres,
   queues: [webhooks: 10],
   pruner: [max_age: 86_400],
   lifeline: [rescue_after: 3_600_000]}
]
```

Set the generated worker's `oban:` option to `MyApp.Oban`, the application
instance, and use its `:webhooks` queue. Its insert joins the ledger repository's
tenant transaction. The delivery persists before the enqueue phase begins;
enqueue failure keeps the durable row available for recovery. The package
writes one tenant key and never rewrites job args after insertion.

Both instances use the PostgreSQL notifier and the same prefix. An available
job's insert publishes on `webhook_jobs.oban_insert` through the inserting
repository; PostgreSQL delivers the notification after commit. The engine
instance listens on that prefix's channel regardless of its instance name.
Its stager also polls for due scheduled and retryable jobs and notifies queues,
so durable jobs remain discoverable after a missed notification. Do not use
isolated notifiers for these separate instances.

Oban calls the worker's real `perform/1` without an ambient tenant binding.
The job tenant supplies each package database phase's binding through
`MyApp.Repo`; the engine repository only manages queue metadata. Ordinary
retryable delivery outcomes snooze the trigger into Oban's `scheduled` state.
An execution error, including a failed database finalization, becomes
`retryable`, or `discarded` when the job exhausts its Oban attempts. Terminal
delivery outcomes can complete the trigger because the delivery row owns the
delivery result and retry ceiling.

Host-scheduled recovery, retention, health, key-lifecycle, and registry sweeps
must run per tenant and pass `tenant:`. A global scan cannot supply a tenant
binding for a multitenant ledger.

## Read routing and other data layers

For AshPostgres and transactional AshSqlite resources, package reads inside a
phase use the transaction's write repository through Ash's data-layer
context. A function `repo` that normally routes reads to another repository
therefore still sees the phase's tenant setting and uncommitted writes.

Data layers without transaction support retain their existing behavior and
are not RLS-capable. Package phases on other data layers are also not
RLS-capable; custody and the registry require transactional AshPostgres or
AshSqlite resources. SQLite repositories must enable `write_transactions?/0`
to use transaction phases; SQLite itself does not provide PostgreSQL policies.
