# Get Started

Both halves of ash_hooks are independently consumable: inbound-only
applications pull no queue infrastructure. This tutorial walks each
half on a resource.

## Inbound: receive, verify, dedup

Declare an inbound source on a resource carrying the
`AshHooks.InboundDelivery` extension:

```elixir
defmodule MyApp.WebhookLedger do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks, AshHooks.InboundDelivery]

  postgres do
    table("webhook_ledgers")
    repo(MyApp.Repo)
  end

  inbound_delivery do
    scope_identity([:account_id])
  end

  attributes do
    attribute(:account_id, :string, allow_nil?: false)
  end

  webhooks do
    inbound :comply_cube do
      # a secret SOURCE, never a literal (ADR-0005)
      secret {:app_env, [:my_app, :complycube_secret]}
    end
  end
end
```

Feed it from your Plug/Phoenix controller — raw body FIRST (a reader
plug), then the ingress:

```elixir
{:ok, :created, delivery} =
  AshHooks.Ingress.ingest(MyApp.WebhookLedger, :comply_cube, raw_body, %{
    signature: signature_header,
    headers: conn.req_headers,
    scope: %{"account_id" => conn.params["account_id"]}
  })

{:ok, token, _claimed} = AshHooks.Ingress.claim_delivery(MyApp.WebhookLedger, delivery.id)
# ... handle the payload ...
{:ok, _} = AshHooks.Ingress.mark_processed(MyApp.WebhookLedger, token, delivery.id)
```

The ledger's storage-level unique index (provider + external_event_id +
scope) is the dedup fence: a concurrent or replayed delivery of the
same webhook returns `{:ok, :duplicate, _}` and never re-processes.

## Outbound: sign, deliver, retry

Declare the outbound event, the subscription + endpoint resources, and
the host-injected worker:

```elixir
defmodule MyApp.Order do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks]

  webhooks do
    outbound :order_paid do
      subscriptions(MyApp.WebhookSubscription)
      deliveries(MyApp.OutboundDelivery)
    end
  end
end

defmodule MyApp.WebhookDeliveryWorker do
  use AshHooks.Worker,
    deliveries: MyApp.OutboundDelivery,
    endpoints: MyApp.WebhookEndpoint,
    secret_resolver: {MyApp.Secrets, :webhook_secret},
    queue: :webhooks,
    oban: MyApp.Oban
end
```

Dispatch fans out to every subscribed endpoint, persists the durable
per-endpoint row, and hands off to your enqueue seam:

```elixir
{:ok, event} = AshHooks.Event.new(type: :order_paid, payload: Jason.encode!(%{"id" => 1}))

{:ok, results} =
  AshHooks.dispatch(MyApp.Order, :order_paid, event,
    enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}
  )
```

Sends are Standard-Webhooks signed (the row's `signing_mode`), retried
on the row's own policy (Retry-After honored, jittered backoff,
dead-letter), and every response snippet stores NO body bytes by
default — a fixed summary of the status and an allowlisted
content-type token. For a one-row diagnostic capture, see
"Dispatch-time capture" in the README.

## Observing: telemetry

```elixir
:telemetry.attach_many("my-ash-hooks", [
  [:ash_hooks, :ingress, :verify],
  [:ash_hooks, :ingress, :dedup],
  [:ash_hooks, :ingress, :claim],
  [:ash_hooks, :dispatch, :enqueue_failed],
  [:ash_hooks, :delivery, :attempt],
  [:ash_hooks, :delivery, :result],
  [:ash_hooks, :delivery, :backoff],
  [:ash_hooks, :delivery, :dead_letter],
  [:ash_hooks, :delivery, :disable]
], fn event, _measurements, metadata, _config ->
  require Logger
  Logger.debug("ash_hooks #{inspect(event)} #{inspect(metadata)}")
end, nil)
```

`attach_many` with the exact names is required — `:telemetry.execute/3`
matches exact names only. Events carry ids, integers, fixed atoms, and
classified reasons — never secrets, bodies, or payloads (ADR-0005).
