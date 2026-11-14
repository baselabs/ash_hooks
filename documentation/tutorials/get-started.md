# Get started

This walkthrough receives a signed order event, records an idempotent business
effect in PostgreSQL, and creates an outbound delivery. It uses an existing Ash
application with PostgreSQL. For a complete SQLite walkthrough and real outbound
request, run the [Livebook](../livebooks/get-started.livemd).

Requires Elixir `~> 1.20`, Erlang/OTP 28 or 29, and Ash
`>= 3.37.2 and < 4.0.0-0`. Inbound works without Oban. Add these entries to your
application's dependency list; the optional Oban entry supports the generated worker.
The dependency-list fragment is tested as part of a Mix project module.

<!-- tested: get-started-dependencies-in-project -->
```elixir
def deps do
  [
    {:ash_hooks, "~> 3.1"},
    {:ash_postgres, "~> 2.0"},
    # Optional: required for the generated Oban worker.
    {:oban, "~> 2.20"}
  ]
end
```

Every supported Ash version requires string-length configuration before resources
compile. Put this fragment in `config/config.exs`, after `import Config`.

<!-- tested: get-started-config-in-application -->
```elixir
config :ash, default_string_length_count: :codepoints
```

## Create the tables

Run this fragment inside the `change/0` function of an Ecto migration. It is
executed against real PostgreSQL as part of this complete application example.
The unique indexes preserve one inbound identity and one delivery per endpoint/event.
The scope column is required on every ingest. Optional response-capture columns
are included below but unused until the endpoint enables that feature.

<!-- tested: get-started-migration-in-application -->
```elixir
# inbound ledger: payload is the decoded body (a :map / JSONB column);
# payload_digest binds it to the signed raw bytes
create table(:webhook_ledgers, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :provider, :text, null: false
  add :external_event_id, :text, null: false
  add :external_event_type, :text
  add :payload, :map, null: false
  add :payload_digest, :text, null: false
  add :status, :text, null: false, default: "received"
  add :fencing_token, :integer, null: false, default: 0
  add :lease_expires_at, :utc_datetime_usec
  add :error_class, :text
  add :attempts, :integer, null: false, default: 0
  # one column per scope_identity slot:
  add :account_id, :text, null: false
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:webhook_ledgers, [:provider, :external_event_id, :account_id])

# outbound ledger: payload here is the exact bytes to sign
create table(:outbound_deliveries, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :event_uuid, :text, null: false
  add :event_type, :text, null: false
  add :payload, :binary, null: false
  add :endpoint_id, :uuid, null: false
  add :subscription_id, :uuid
  add :signing_mode, :text
  add :status, :text, null: false, default: "pending"
  add :attempts, :integer, null: false, default: 0
  add :response_status, :integer
  add :response_snippet, :text
  add :last_error, :text
  add :next_attempt_at, :utc_datetime_usec
  add :dispatch_source, :text, null: false, default: "v1:direct:unbound"
  add :dispatch_route, :text, null: false, default: "v1:route:unbound"
  add :attempt_token, :uuid
  add :send_lease_expires_at, :utc_datetime_usec
  add :enqueue_token, :uuid
  add :enqueue_lease_expires_at, :utc_datetime_usec
  add :endpoint_snapshot, :map
  timestamps(type: :utc_datetime_usec)
end

create unique_index(:outbound_deliveries, [:endpoint_id, :event_uuid])

create table(:webhook_endpoints, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :url, :text, null: false
  add :status, :text, null: false, default: "enabled"
  add :secret_ref, :text, null: false
  add :previous_secret_ref, :text
  add :legacy_secret_ref, :text
  add :legacy_previous_secret_ref, :text
  # only when the endpoint declares `response_capture_attributes :on`:
  add :response_capture, :boolean, null: false, default: false
  add :response_capture_max_bytes, :integer, null: false, default: 2048
  add :response_capture_retention_seconds, :integer, null: false, default: 2_592_000
  add :response_header_allowlist, {:array, :text}, null: false, default: []
end

# the attempt history (optional; see "Delivery logs and attempt history"):
# one row per delivery attempt, written by the runtime
create table(:outbound_attempts, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :delivery_pk, :map, null: false
  add :endpoint_id, :uuid, null: false
  add :event_uuid, :text, null: false
  add :event_type, :text, null: false
  add :attempt, :integer, null: false
  add :outcome, :text, null: false
  add :reason, :text
  add :response_status, :integer
  add :response_snippet, :text
  add :response_headers, :map
  add :latency_ms, :integer
  add :signing_key_ref, :text
  add :test, :boolean, null: false, default: false
  add :attempted_at, :utc_datetime_usec, null: false
end

create unique_index(:outbound_attempts, [:delivery_pk, :attempt])

create table(:webhook_subscriptions, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :event_types, {:array, :text}, null: false
  add :endpoint_id, :uuid, null: false
  add :signing_mode, :text
end

create table(:orders, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :paid, :boolean, null: false, default: false
end
```

## Declare the resources

The following complete example uses the tables above. Put each module in its own
source file in your application. Configure `MyApp.Repo` with your PostgreSQL
connection and supervise it before making calls. Register `MyApp.Domain` in your
application's `:ash_domains` configuration. These resources are called by trusted
application code; add policies before exposing them to actors.

<!-- tested: get-started-resources-in-application -->
```elixir
defmodule MyApp.Repo do
  use AshPostgres.Repo,
    otp_app: :my_app,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule MyApp.Order do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks]

  postgres do
    table "orders"
    repo MyApp.Repo
  end

  attributes do
    uuid_primary_key :id
    attribute :paid, :boolean, allow_nil?: false, default: false
  end

  actions do
    defaults [:read, :create, :update]
    default_accept [:paid]
  end

  webhooks do
    outbound :order_paid do
      subscriptions MyApp.WebhookSubscription
      deliveries MyApp.OutboundDelivery
    end
  end
end

defmodule MyApp.Webhooks.Orders do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-orders-signature"},
      encoding: :hex
    ]

  @impl true
  def parse_event_type(%{"type" => "order.paid"}), do: {:ok, :order_paid}
  def parse_event_type(_payload), do: {:error, :unknown_event_type}

  @impl true
  def handle_event(:order_paid, %{"order_id" => id} = payload) do
    # Setting the same paid flag twice has the same business effect as once.
    with {:ok, order} <- Ash.get(MyApp.Order, id, authorize?: false),
         {:ok, _order} <- Ash.update(order, %{paid: true}, authorize?: false) do
      {:ok, %AshHooks.Provider.Event{type: :order_paid, payload: payload}}
    else
      {:error, reason} -> {:error, :retry, reason}
    end
  end

  def handle_event(_type, _payload), do: {:error, :permanent, :unhandled_event}
end

defmodule MyApp.WebhookLedger do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks, AshHooks.InboundDelivery]

  postgres do
    table "webhook_ledgers"
    repo MyApp.Repo
  end

  inbound_delivery do
    scope_identity [:account_id]
  end

  attributes do
    attribute :account_id, :string, allow_nil?: false
    timestamps()
  end

  actions do
    defaults [:read]
  end

  webhooks do
    inbound :orders do
      provider MyApp.Webhooks.Orders
      secret {:app_env, [:my_app, :orders_webhook_secret]}
      event_id &__MODULE__.event_id/1
    end
  end

  def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  def event_id(_payload), do: :error
end

defmodule MyApp.WebhookEndpoint do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.Endpoint]

  postgres do
    table "webhook_endpoints"
    repo MyApp.Repo
  end

  actions do
    defaults [:read, :create, :update]
    default_accept :*
  end
end

defmodule MyApp.WebhookSubscription do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.Subscription]

  postgres do
    table "webhook_subscriptions"
    repo MyApp.Repo
  end

  actions do
    defaults [:read, :create]
    default_accept :*
  end

  subscription do
    endpoint_resource MyApp.WebhookEndpoint
  end
end

defmodule MyApp.OutboundDelivery do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.OutboundDelivery]

  postgres do
    table "outbound_deliveries"
    repo MyApp.Repo
  end

  actions do
    defaults [:read]
  end

  attributes do
    timestamps()
  end
end

defmodule MyApp.OutboundAttempt do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.OutboundAttempt]

  postgres do
    table "outbound_attempts"
    repo MyApp.Repo
  end

  actions do
    defaults [:read]
  end
end

defmodule MyApp.Domain do
  use Ash.Domain, otp_app: :my_app

  resources do
    resource MyApp.Order
    resource MyApp.WebhookLedger
    resource MyApp.WebhookEndpoint
    resource MyApp.WebhookSubscription
    resource MyApp.OutboundDelivery
    resource MyApp.OutboundAttempt
  end
end
```

`provider` is required. The inbound name is part of the ledger identity and must
stay stable. The explicit event ID extractor takes precedence; invalid results
use the raw-body digest. Without it, a provider identity callback is used when
implemented, and an invalid provider identity fails ingestion. With neither,
ingress uses the raw-body SHA-256.

## Verify and handle an incoming event

The following calls run after the resources and migration above. This example
sets an application secret, creates an order, signs exact bytes, and ingests twice.
In production, load the secret through your configured secret store. It is never
embedded in the compiled webhook declaration. Use unique event IDs for distinct
events, and reuse the ID for redelivery.

<!-- tested: get-started-ingress-in-application -->
```elixir
Application.put_env(:my_app, :orders_webhook_secret, :crypto.strong_rand_bytes(32))
{:ok, order} = Ash.create(MyApp.Order, %{}, authorize?: false)
raw_body = Jason.encode!(%{"type" => "order.paid", "id" => "event-1", "order_id" => order.id})
secret = Application.fetch_env!(:my_app, :orders_webhook_secret)
signature = :crypto.mac(:hmac, :sha256, secret, raw_body) |> Base.encode16(case: :lower)
ctx = %{headers: [{"x-orders-signature", signature}], scope: %{account_id: "account-1"}}
{:ok, :created, %{status: :processed}} =
  AshHooks.Ingress.ingest(MyApp.WebhookLedger, :orders, raw_body, ctx)
{:ok, :duplicate, %{status: :processed}} =
  AshHooks.Ingress.ingest(MyApp.WebhookLedger, :orders, raw_body, ctx)
{:ok, %{paid: true}} = Ash.get(MyApp.Order, order.id, authorize?: false)
```

The ledger runs handlers at least once. A crash between the business effect and
recording success can repeat the handler. This handler's update is idempotent.
Returned retry and permanent failures are recorded; a handler exception, exit,
or throw can escape synchronous ingestion. An expired claim can later recover.

For HTTP receipt, configure `AshHooks.BodyReader` before parsers consume the bytes,
then mount `AshHooks.Plug`. The [README](../../README.md#receive-with-ashhooksplug)
contains tested Phoenix mounting fragments. Scoped and multitenant routes need a
stored-endpoint resolver returning the source, scope, connection, and tenant.
Never trust a path parameter as a module or tenant.

The plug acknowledges terminal rows with 200, returns 500 for pending, claimed,
or retryable outcomes, 400 for typed invalid-signature/stale-timestamp/malformed
errors, and 503 for other ingestion errors. Default 503s include `retry-after`.
Permanent failures need an operator-visible record because redelivery cannot
repair a terminal row. See `AshHooks.Plug` for custom response and refusal callbacks.

## Create an outbound delivery

Use the existing public receiver you control: set `PUBLIC_WEBHOOK_TEST_URL` to
its public HTTPS webhook URL. This example only creates the durable row. It does
not send until a worker or the direct runner drives it. Endpoint registration
rejects private, loopback, and special-purpose literal IP addresses. DNS names
are resolved and checked at send time.
The notebook shows an explicit local destination policy for its existing receiver.

<!-- tested: get-started-dispatch-in-application -->
```elixir
{:ok, endpoint} = Ash.create(MyApp.WebhookEndpoint, %{
  url: System.fetch_env!("PUBLIC_WEBHOOK_TEST_URL"), secret_ref: "outbound-main"
}, authorize?: false)
{:ok, _subscription} = Ash.create(MyApp.WebhookSubscription, %{
  endpoint_id: endpoint.id, event_types: ["order_paid"]
}, authorize?: false)
{:ok, event} = AshHooks.Event.new(
  type: :order_paid, payload: Jason.encode!(%{order_id: order.id}), id: "msg_order-" <> order.id
)
{:ok, [%{status: :deferred}]} = AshHooks.dispatch(MyApp.Order, :order_paid, event)
{:ok, %{records: [delivery]}} = AshHooks.Delivery.list(MyApp.OutboundDelivery,
  endpoint_id: endpoint.id, status: [:pending]
)
```

For queued delivery, add an Oban migration, supervise an Oban instance with a
`:webhooks` queue, and define this worker. Set `oban:` to the supervised instance
name; omit it for the default `Oban` instance. The worker is compiled with this
application example; the notebook executes direct delivery to its real receiver.

<!-- tested: get-started-worker-in-application -->
```elixir
defmodule MyApp.Secrets do
  def webhook_secret("outbound-main") do
    case System.fetch_env("OUTBOUND_WEBHOOK_SECRET") do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :missing_secret}
    end
  end

  def webhook_secret(_unknown), do: {:error, :unknown_reference}
end

defmodule MyApp.WebhookDeliveryWorker do
  use AshHooks.Worker,
    deliveries: MyApp.OutboundDelivery,
    endpoints: MyApp.WebhookEndpoint,
    attempts: MyApp.OutboundAttempt,
    secret_resolver: {MyApp.Secrets, :webhook_secret},
    queue: :webhooks,
    oban: MyApp.Oban
end
```

Generate a signing secret once with `AshHooks.Signing.generate_secret/0`, store the
complete value under the endpoint reference, and return it unchanged. Dispatch
with `enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}` once Oban is running.
Schedule `AshHooks.reconcile_pending/3` for every declaration and tenant using the
same callback. It repairs persistence/enqueue gaps, due retries, expired sends,
and pending 410 disables. Delivery remains at least once across the network.
Receivers deduplicate by `webhook-id`; keep application clocks synchronized.

The worker signs according to Standard Webhooks, succeeds on 2xx responses,
retries 408/429/5xx and transport errors, refuses redirects, and permanently fails
other client errors. Retry-After is bounded; otherwise retries use exponential
backoff with random delay. HTTP 410 records a pending disable obligation before
conditionally disabling the matching endpoint configuration. Use telemetry to
make failures and endpoint disablement visible to operators.

## Other optional features

- Attempt history uses the resource and migration above. Pass `attempts:` to the
  worker or direct runner. History-write failure emits telemetry without undoing
  the completed result transition. HTTP 410 history omits duration and key reference.
- Query deliveries and attempts with keyset pagination. Pass each query's own
  `next_cursor` back as `after:`; do not share cursors between different queries.
  A full last page still has a cursor, and a shorter page has nil.
- Endpoint opt-in captures bounded, redacted response bodies in attempt history.
  Delivery rows contain a summary unless a direct run sets `snippet_capture: true`.
  Retryable rows must be due; terminal rows must first be rearmed with `resend/2`.
- `payload_attribute` renames the delivery's byte column. `prune_action :none`
  prevents injection of `:prune`; application-defined destroy actions remain.
  Endpoint mapping uses an application enable switch. Subscription event types
  can be constrained atoms or strings; application declarations replace generated
  constraints and defaults.
- Test sends, resend, bulk replay, key rolling, catalog metadata, payload versions,
  subscription filters, an event log, custom transports, inbound queries, pausing,
  secret rotation, and a destination policy callback are documented at their modules.
  Read the replay, health, tenancy, and retention limitations in the README before
  enabling those features.

Applications own policies, queue and retention schedules, and secret storage.
Inbound pruning excludes tracked rejected-verification rows. Delivery pruning
ignores history-deletion errors. Optional resources need the same tenant contract
and matching indexes as the core resources.

## Observing: telemetry

This example observes the basic delivery lifecycle. See `AshHooks.Telemetry` for
all optional-feature events. The fragment runs inside this application example.

<!-- tested: get-started-telemetry-in-application -->
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
], fn event, measurements, metadata, _config ->
  require Logger
  Logger.debug("#{inspect(event)} #{inspect(measurements)} #{inspect(metadata)}")
end, nil)
```

Forward measurements and identifiers to your metrics system. `attach_many` matches exact names; events omit bodies,
payloads, and signing secrets.

Next: the [verification guide](verify-any-sender.md), [tenancy checklist](tenancy-adoption-checklist.md),
and [upgrade guide](../../UPGRADING.md).
