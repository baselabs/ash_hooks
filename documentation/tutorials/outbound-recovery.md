# Retain events and recover deliveries

Start with the resources, repository, migrations, and secret resolver in
[get started](get-started.md). This guide extends that application. Apply the
migration before deploying the resource declarations. The application owns
policies, schedules, and access to retained payloads.

## Store events independently of deliveries

Add this resource and register it in `MyApp.Domain`. It records an event even
when no endpoint is subscribed or enabled. It needs its own retention policy.

<!-- tested: recovery-event-resource -->
```elixir
defmodule MyApp.OutboundEvent do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.OutboundEvent]

  postgres do
    table "outbound_events"
    repo MyApp.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    timestamps()
  end
end
```

Add this section to `MyApp.OutboundDelivery` to record replay requests:

<!-- tested: recovery-delivery-options -->
```elixir
outbound_delivery do
  resend_tracking :on
end
```

Add these statements to a new `Ecto.Migration`'s `change/0`:

<!-- tested: recovery-migration -->
```elixir
create table(:outbound_events, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :event_uuid, :text, null: false
  add :event_type, :text, null: false
  add :version, :integer
  add :payload, :binary, null: false
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:outbound_events, [:event_uuid])

alter table(:outbound_deliveries) do
  add :resend_baseline, :integer, null: false, default: 0
  add :resend_count, :integer, null: false, default: 0
  add :last_resend_by, :text
  add :last_resend_at, :utc_datetime_usec
end
```

Add `events MyApp.OutboundEvent` to the `outbound :order_paid` declaration.
The [catalog guide](outbound-contracts.md) shows a complete replacement
`webhooks` section that includes it.

## Preview and replay a retained event

After dispatching an event, select it by its original ID. This example uses
`event` and `endpoint` from the dispatch example. Authorize the operator before
calling these system helpers. `requested_by` is a durable audit identifier,
not a credential.

<!-- tested: recovery-replay -->
```elixir
{:ok, %{records: [logged]}} =
  AshHooks.OutboundEvent.list(MyApp.OutboundEvent, event_uuid: event.id)

replay_options = [
  event_uuid: logged.event_uuid,
  deliveries: MyApp.OutboundDelivery,
  endpoints: MyApp.WebhookEndpoint,
  declaration: {MyApp.Order, :order_paid},
  requested_by: "operator-recovery",
  limit: 100,
  per_second: 25
]

{:ok, %{count: 1}} =
  AshHooks.OutboundEvent.replay(
    MyApp.OutboundEvent,
    endpoint,
    Keyword.put(replay_options, :dry_run, true)
  )

{:ok, %{created: _, re_sent: _, skipped: _, errors: _} = replay_counts} =
  AshHooks.OutboundEvent.replay(MyApp.OutboundEvent, endpoint, replay_options)
```

A new endpoint gets a new delivery preserving the event ID and bytes. An
existing terminal delivery is rearmed; a pending or retrying delivery is
skipped. Check `created`, `re_sent`, `skipped`, and `errors` rather than treating
a successful call as proof every event was delivered. `errors` holds the
per-row error terms from delivery reads, replay creates, and terminal resends.
Those failures do not increment `skipped`; only live, nonterminal rows do.
An unknown event returns
`:event_not_found`; missing or mismatched declarations fail before replay.

For a queued application, pass the same `enqueue: {MyApp.WebhookDeliveryWorker,
:enqueue}` callback used by dispatch. Without it, rows remain pending for the
direct runner. Anonymous queue callbacks require a stable `enqueue_key` for
scheduled recovery. Schedule `AshHooks.reconcile_pending/3` for each declaration,
queue route, and tenant. It recovers persistence/enqueue gaps and expired leases.

Filter bulk replay with `event_type: "order_paid"` and explicit `from:` / `to:`
bounds instead of `event_uuid:`. Each call selects a bounded batch; replay has
no continuation cursor. Advance the time range or select IDs to progress past
skipped or failed rows. Receivers must deduplicate the preserved `webhook-id` because
network delivery remains at least once.

## Own retention and tenant boundaries

Schedule event pruning independently of delivery and attempt retention:

<!-- tested: recovery-retention -->
```elixir
cutoff = DateTime.add(DateTime.utc_now(), -30 * 86_400, :second)
{:ok, deleted_events} = AshHooks.OutboundEvent.prune(MyApp.OutboundEvent, older_than: cutoff)
```

A log write failure emits `[:ash_hooks, :event, :record_failed]` and does not
undo delivery creation. Alert on that event and repair storage before relying
on the log for recovery. List and prune return storage errors to the caller.
Protect the injected `:record` and `:prune` actions with application policies.

For a multitenant application, declare matching attribute tenancy on the
emitter, endpoints, subscriptions, deliveries, attempts, and event log. Add the
tenant column to each migration and tenant to every unique index. Pass the same
`tenant:` to dispatch, list, replay, pruning, workers, and reconciliation. Missing
tenants fail before data access; never run a global recovery query for tenants.
