# Get Started

This walkthrough takes a new application from install to a verified
inbound webhook and a delivered outbound webhook. Both halves are
independently consumable: inbound-only applications need no Oban.

Requirements: Elixir ~> 1.15, Ash ~> 3.0. Optional components: Oban
(~> 2.20) for outbound delivery, Plug/Phoenix for inbound receipt.

## Installation

```elixir
def deps do
  [
    {:ash_hooks, "~> 0.1.0"},
    # for outbound delivery only:
    {:oban, "~> 2.20"}
  ]
end
```

Or `mix igniter.install ash_hooks`, which also ATTEMPTS to patch your
endpoint's `Plug.Parsers` with a `body_reader` (see below) — review the
generated diff; if the patch could not be applied, add it by hand.

## The database migrations

ash_hooks injects fields and identities onto YOUR resources; your
migrations create the tables and — critically — the two UNIQUE INDEXES
that make the dedup guarantees real. Minimal shapes:

```elixir
# inbound ledger (scope_identity extends the identity below)
create table(:webhook_ledgers, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :provider, :text, null: false
  add :external_event_id, :text, null: false
  add :external_event_type, :text
  add :payload, :text, null: false
  add :payload_digest, :text, null: false
  add :status, :text, null: false, default: "received"
  add :fencing_token, :integer, null: false, default: 0
  add :lease_expires_at, :utc_datetime_usec
  add :error_class, :text
  add :attempts, :integer, null: false, default: 0
  # one column per scope_identity slot:
  add :account_id, :text, null: false
end

create unique_index(:webhook_ledgers, [:provider, :external_event_id, :account_id])

# outbound ledger
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
end

create unique_index(:outbound_deliveries, [:endpoint_id, :event_uuid])

# endpoints + subscriptions (columns per their DSL cheat sheets)
```

## Inbound: receive, verify, dedup

Configure the raw-body reader FIRST — signature schemes sign the exact
wire bytes, and a router plug cannot recover pre-parser bytes:

```elixir
# in your Phoenix Endpoint:
plug Plug.Parsers,
  parsers: [:json],
  pass: ["*/*"],
  body_reader: {AshHooks.BodyReader, :read_body, []},
  # optional: scope the raw-body memory cost to webhook routes only
  # body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]},
  json_decoder: Phoenix.json_library()
```

The ledger resource (one resource per inbound surface):

```elixir
defmodule MyApp.WebhookLedger do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,   # or AshSqlite.DataLayer
    extensions: [AshHooks, AshHooks.InboundDelivery]

  postgres do
    table("webhook_ledgers")
    repo(MyApp.Repo)
  end

  inbound_delivery do
    # provider event ids are NOT globally unique across accounts — your
    # scope slots extend the unique-ingest identity (each slot must be a
    # non-nullable attribute, supplied on every ingest)
    scope_identity([:account_id])
  end

  attributes do
    attribute(:account_id, :string, allow_nil?: false)
  end

  actions do
    defaults([:read])
  end

  webhooks do
    inbound :comply_cube do
      # convention-resolves the provider to AshHooks.Provider.ComplyCube;
      # a SECRET SOURCE, never a literal
      secret {:app_env, [:my_app, :complycube_secret]}
    end
  end
end
```

`AshHooks.Ingress.ingest/4` runs the whole sync pipeline — verify the
signature, persist the raw payload, dedup on the unique index, claim
under a fenced lease, invoke the provider handler, and mark the
outcome. From your controller:

```elixir
raw = conn.private[:ash_hooks_raw_body]

case AshHooks.Ingress.ingest(MyApp.WebhookLedger, :comply_cube, raw, %{
       signature: List.first(get_req_header(conn, "complycube-signature")),
       headers: Map.new(conn.req_headers),
       scope: %{"account_id" => conn.params["account_id"]}
     }) do
  {:ok, :created, delivery} ->
    # the handler ran; delivery.status is :processed, :failed_retryable,
    # or :failed_permanent — check it to pick your HTTP response
    send_resp(conn, status_for(delivery.status), "")

  {:ok, :duplicate, _delivery} ->
    # already seen — respond however the provider expects a replay
    send_resp(conn, 200, "")

  {:error, _invalid_signature_or_payload} ->
    send_resp(conn, 400, "")
end
```

Dedup semantics: a delivery whose row is terminal (`:processed` /
`:failed_permanent`) is never processed again; a retryable or stranded
duplicate MAY be re-driven under lease fencing — exactly-once handling,
at-least-once delivery. `claim_delivery/2`, `mark_processed/3`,
`mark_failed/5`, `renew/3` and `reap/1` are public if you need to drive
the lease machine yourself (e.g. from your own async pipeline) — the
sync `ingest/4` above is the default.

Crash safety: once the durable row exists, a crash between any two
steps re-drives on redelivery instead of silently dropping.

## Outbound: sign, deliver, retry

The three resources:

```elixir
defmodule MyApp.WebhookEndpoint do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.Endpoint]

  postgres do
    table("webhook_endpoints")
    repo(MyApp.Repo)
  end

  actions do
    defaults([:read, :create, :update])
    default_accept(:*)
  end
end

defmodule MyApp.WebhookSubscription do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.Subscription]

  postgres do
    table("webhook_subscriptions")
    repo(MyApp.Repo)
  end

  actions do
    defaults([:read, :create])
    default_accept(:*)
  end

  subscription do
    endpoint_resource(MyApp.WebhookEndpoint)
  end
end

defmodule MyApp.OutboundDelivery do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks.OutboundDelivery]

  postgres do
    table("outbound_deliveries")
    repo(MyApp.Repo)
  end

  actions do
    defaults([:read])
  end
end
```

The emitting resource declares the event:

```elixir
defmodule MyApp.Order do
  use Ash.Resource,
    domain: MyApp.Domain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshHooks]

  # ... your attributes/actions ...

  webhooks do
    outbound :order_paid do
      subscriptions(MyApp.WebhookSubscription)
      deliveries(MyApp.OutboundDelivery)
    end
  end
end
```

The worker (ONE module, in your app — Oban must be in your deps):

```elixir
defmodule MyApp.WebhookDeliveryWorker do
  use AshHooks.Worker,
    deliveries: MyApp.OutboundDelivery,
    endpoints: MyApp.WebhookEndpoint,
    secret_resolver: {MyApp.Secrets, :webhook_secret},
    queue: :webhooks,
    oban: MyApp.Oban
end
```

The secret resolver maps an endpoint's secret REFERENCE to its value —
endpoints store references only, never secrets:

```elixir
defmodule MyApp.Secrets do
  # ref is whatever string you stored on the endpoint's secret_ref
  def webhook_secret("acme-main") do
    {:ok, "whsec_" <> System.get_env("ACME_WEBHOOK_SECRET")}
  end

  def webhook_secret(_unknown), do: {:error, :unknown_ref}
end
```

Oban itself (dependency, migration, and a supervised instance with a
`:webhooks` queue) is the consumer's to set up — see Oban's install
guide; the worker above plugs into it.

Register an endpoint and a subscription, then dispatch:

```elixir
{:ok, endpoint} =
  Ash.create(MyApp.WebhookEndpoint, %{
    url: "https://partner.example.test/hooks",
    secret_ref: "acme-main"
  }, authorize?: false)

{:ok, _sub} =
  Ash.create(MyApp.WebhookSubscription, %{
    endpoint_id: endpoint.id,
    event_types: ["order_paid"]
  }, authorize?: false)

{:ok, event} = AshHooks.Event.new(type: :order_paid, payload: Jason.encode!(%{"id" => 1}))

{:ok, results} =
  AshHooks.dispatch(MyApp.Order, :order_paid, event,
    enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}
  )
```

With no `enqueue:` the rows persist `:pending` (durable ledger only,
nothing sends). With the worker seam wired, each row is delivered by
`AshHooks.Delivery`: Standard-Webhooks signed, retried with bounded
Retry-After and jittered backoff, dead-lettered at the ceiling, the
endpoint durably disabled on 410.

Signing modes: `:standard` (default) signs with the resolved
`secret_ref` value. `:dual` additionally emits a legacy envelope for
receivers mid-migration — it REQUIRES the endpoint to also carry a
`legacy_secret_ref`. `:legacy` signs only that envelope.

Response snippets store NO body bytes by default (a status +
content-type summary). For a one-row diagnostic capture see
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
