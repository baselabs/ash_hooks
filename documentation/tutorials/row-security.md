# Row-level security

AshHooks opens a bounded Ash transaction for each database phase, passing the
operation's `tenant:` in the transaction reason. The host repository binds that
tenant to its PostgreSQL policies. HTTP requests, inbound handlers, custody
callbacks, and retry sleeps run outside the package's phases.

Every row-secured package resource must declare Ash multitenancy, using an
attribute or context strategy supported by its data layer and the entry point.
The package's tenancy preflight currently admits compatible attribute tenancy;
its existing context-strategy refusals still apply. A forced table
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
          to_string(Ash.ToTenant.to_tenant(tenant, nil))
        ])

        :ok
    end
  end
end
```

`set_config(name, value, true)` makes the setting transaction-local. Both commit
and rollback clear it before the pooled connection is reused. Read only
`reason[:tenant]`; neither a process dictionary nor a worker wrapper supplies
the tenant.

A package phase inside a host transaction joins that transaction and does not
call the hook again. Bind the outermost transaction with the same tenant, for
example through `Ash.transact(resources, callback, tenant: tenant)`. Do not mix
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

## Secure tables and jobs

Generate the ordinary resource migrations first. Enable and force row-level
security on every package table your application uses: endpoints,
subscriptions, deliveries, attempts, event logs, inbound ledgers, and custody
registries. The application role must neither own these tables nor have
superuser or `BYPASSRLS` privileges.

For a text tenant attribute named `tenant_id`, both the policy's `USING` and
`WITH CHECK` expressions can use
`tenant_id = current_setting('my_app.tenant', true)`. Apply the policy to every
operation the application role needs. Cast according to the actual tenant
column type. Enable `FORCE ROW LEVEL SECURITY` as well as `ENABLE ROW LEVEL
SECURITY`, and verify access through the application role with no binding.

On multitenant ledgers the job args carry the row's tenant under "tenant"; for the string, integer or atom tenants a job can carry, `Ash.ToTenant` is the identity, so its text equals what a repository's `on_transaction_begin/1` derives from the transaction's tenant, and a host can secure its job table on `args->>'tenant'`.

Use `args->>'tenant' = current_setting('my_app.tenant', true)` for the job
table's policy. The generated worker inserts through the Oban instance named
by its `oban:` option. Configure that instance with the ledger's repository so
the job insert joins the tenant phase. The delivery persists before the enqueue
phase begins; enqueue failure keeps the durable row available for recovery.
The package writes one tenant key and never rewrites job args after insertion.
Call the worker's real `perform/1` directly through Oban, without a tenant
wrapper. The job tenant supplies each database phase's binding.

Host-scheduled recovery, retention, health, key-lifecycle, and registry sweeps
must run per tenant and pass `tenant:`. A global scan cannot supply a tenant
binding for a multitenant ledger.

## Read routing and other data layers

For AshPostgres and transactional AshSqlite resources, package reads inside a
phase use the transaction's mutate repository through Ash's data-layer
context. A function `repo` that normally routes reads to another repository
therefore still sees the phase's tenant setting and uncommitted writes.

Data layers without transaction support retain their existing behavior and
are not RLS-capable. Package phases on other data layers are also not
RLS-capable; custody and the registry require transactional AshPostgres or
AshSqlite resources. SQLite repositories must enable `write_transactions?/0`
to use transaction phases; SQLite itself does not provide PostgreSQL policies.
