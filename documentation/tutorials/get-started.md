# Get Started

This walkthrough takes a new application from install to a verified
inbound webhook and a delivered outbound webhook. Both halves are
independently consumable: inbound-only applications need no Oban.

Requirements: Elixir ~> 1.20 (OTP 28+), Ash >= 3.37.2, < 4.0. Optional components: Oban
(~> 2.20) for outbound delivery, Plug/Phoenix for inbound receipt.

This walkthrough builds on a working Ash application: one with a
domain, a repo (Postgres or sqlite), and a migration workflow. If you
are starting from an empty directory, follow
[Ash's get-started guide](https://hexdocs.pm/ash/get-started.html) first; the
examples below refer to your existing `MyApp.Domain` and `MyApp.Repo`
(your names will differ).

## Installation

```elixir
def deps do
  [
    {:ash_hooks, "~> 3.1"},
    # for outbound delivery only:
    {:oban, "~> 2.20"}
  ]
end
```

Or `mix igniter.install ash_hooks`, which also attempts to patch your
endpoint's `Plug.Parsers` with a `body_reader` (see below); review the
generated diff; if the patch could not be applied, add it by hand.

One Ash-side requirement to know about: Ash 3.33 and later require every
application to choose how string length is counted, and compiling any
resource fails until it is set:

```elixir
# config/config.exs
config :ash, default_string_length_count: :codepoints
```

`:codepoints` is Ash's recommendation: `max_length` bounds value size
and matches how SQL data layers count. `:mixed` keeps the pre-3.33
grapheme counting if you need it. This is an Ash requirement for every
app compiling resources, not an ash_hooks one; an application already on
Ash 3.33+ necessarily has it set.

## The database migrations

ash_hooks injects fields and identities onto your resources; your
migrations create the tables and, critically, the two unique indexes
that make the dedup guarantees real. Minimal shapes:

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
  add :attempted_at, :utc_datetime_usec, null: false
end

create unique_index(:outbound_attempts, [:delivery_pk, :attempt])

create table(:webhook_subscriptions, primary_key: false) do
  add :id, :uuid, primary_key: true
  add :event_types, {:array, :text}, null: false
  add :endpoint_id, :uuid, null: false
  add :signing_mode, :text
end
```

These are PostgreSQL migrations. For SQLite examples, the
[guided tour](../livebooks/get-started.livemd) creates its tables and JSON columns
against a real SQLite database.

## Inbound: receive, verify, dedup

Configure the raw-body reader first: signature schemes sign the exact
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

If your endpoint already has a body reader, keep it and call
`AshHooks.BodyReader.put_raw_body(conn, complete_bytes)` from that reader or
before parsing. Supply the entire body exactly as sent, never partial or
re-encoded bytes. The plug retrieves it through `AshHooks.BodyReader.raw_body/1`
without reading it again; direct ingress callers can use the same accessor.

Describe the sender in a provider module. This one verifies a lowercase-hex
HMAC-SHA256 of the raw body sent in `x-orders-signature`, and maps the sender's
event names to atoms your handler understands:

```elixir
defmodule MyApp.Webhooks.Orders do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-orders-signature"},
      encoding: :hex
    ]

  @types %{"order.paid" => :order_paid}

  @impl true
  def parse_event_type(%{"type" => type}) do
    case Map.fetch(@types, type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unknown_event_type}
    end
  end

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  # Must be idempotent: a crash after this runs and before the ledger
  # records it re-runs it on redelivery.
  @impl true
  def handle_event(:order_paid, %{"order_id" => order_id} = payload) do
    with {:ok, _order} <- MyApp.Orders.mark_paid(order_id) do
      {:ok, %AshHooks.Provider.Event{type: :order_paid, payload: payload}}
    else
      {:error, reason} -> {:error, :retry, reason}
    end
  end

  def handle_event(_type, _payload), do: {:error, :permanent, :unhandled_event}
end
```

Your sender documents its own scheme: which header, which algorithm, how the
secret and signature are encoded, what is signed, and whether a timestamp is
included. Translate it into `verify:` options with the
[Verify any sender](verify-any-sender.md) guide, which has recipes for common
shapes, from structured `t=...,v1=...` headers to RSA signatures and JWS bodies.

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
    # provider event ids are not globally unique across accounts; your
    # scope slots extend the unique-ingest identity (each slot must be a
    # non-nullable attribute, supplied on every ingest)
    scope_identity([:account_id])
  end

  attributes do
    attribute(:account_id, :string, allow_nil?: false)
    timestamps()
  end

  actions do
    defaults([:read])
  end

  webhooks do
    inbound :orders do
      provider MyApp.Webhooks.Orders
      # a secret source, never a literal
      secret {:app_env, [:my_app, :orders_webhook_secret]}
      # the sender's event id: the deduplication identity
      event_id(&__MODULE__.event_id/1)
    end
  end

  def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
  def event_id(_payload), do: :error
end
```

`provider` is required: the inbound name (`:orders`) identifies the source in
the ledger and resolves no module. Keep it stable once deliveries are recorded,
because it is part of every deduplication identity. Without an `event_id`
extractor or a provider `event_identity/1` callback, the SHA-256 of the raw body
is the identity. The [provider API](https://hexdocs.pm/ash_hooks/AshHooks.Provider.html)
describes every callback.

Register the ledger in your existing domain before calling ingress. Keep any
resources your application already declares:

```elixir
defmodule MyApp.Domain do
  use Ash.Domain, otp_app: :my_app

  resources do
    resource(MyApp.WebhookLedger)
    # ... your existing resources ...
  end
end
```

`AshHooks.Plug` runs the whole sync pipeline: verify the
signature over the raw bytes, persist the decoded payload plus a digest
binding it to those bytes, dedup on the unique index, claim under a
fenced lease, invoke the provider handler, and mark the outcome. After configuring
the endpoint's `Plug.Parsers` with `AshHooks.BodyReader` above, forward the webhook
prefix in your Phoenix router, outside browser/session/CSRF pipelines:

```elixir
forward "/webhooks", AshHooks.Plug,
  resource: MyApp.WebhookLedger,
  resolve: {MyApp.Webhooks, :resolve, []},
  request_uri: "https://hooks.example.com"

defmodule MyApp.Webhooks do
  # /webhooks/:provider/:endpoint_id; the forwarded conn retains these segments.
  def resolve(%Plug.Conn{path_info: [provider, endpoint_id]}) do
    case MyApp.Integrations.find_webhook_endpoint(provider, endpoint_id) do
      {:ok, endpoint} ->
        {:ok, %{source: endpoint.source, scope: %{account_id: endpoint.account_id},
                connection: endpoint.connection}}

      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  def resolve(_conn), do: {:error, :not_found}
end
```

The lookup is your application's code interface for a stored endpoint; do not
turn path strings into modules or trust them as tenants. Match its scope keys to
the ledger's `scope_identity`. A multitenant ledger also needs `tenant:` in that
map (see the [tenancy checklist](tenancy-adoption-checklist.md)). On a
single-tenant ledger without scope slots, a fixed route can use `source: :orders`
instead of `resolve:`.

The plug sends and halts: 200 for terminal rows (including duplicate deliveries),
500 for retryable ledger outcomes, 400 for typed invalid-signature, stale-timestamp
or malformed-payload errors, and 503 for other ingest failures. Resolver failures
answer 404 or 503 without writing. POST is the default allowed method (405 with
`allow` otherwise). Direct body reads default to an 8,000,000-byte limit (413 on
overflow); when a parser runs first its own body limit applies.

The configured public base URI gets the request's original path and query appended.
An MFA can return the full URI instead. The default supplies no URI, and the plug
never uses the conn's internal host, scheme or port. Provider `handshake/1` can
answer subscription challenges before method/signature checks. Provider
`response/1`, then the plug's `respond:` MFA, may customize ingest responses;
`:default` falls through to `AshHooks.Plug.default_response/2`, taking the outcome
and validated plug options. Default 503s include `retry-after` (60 seconds;
configure `retry_after:`). A `refuse:` MFA can shape refusal headers and body
without changing status or required `allow`/`retry-after` headers.

For a custom transport or pipeline, call the lower-level entry point directly:

```elixir
AshHooks.Ingress.ingest(MyApp.WebhookLedger, :orders, raw_body, %{
  headers: conn.req_headers, method: conn.method,
  scope: %{account_id: account_id},
  request_uri: public_request_uri
})
```

The ledger deduplicates deliveries and invokes handlers at least once.
A delivery whose row is terminal (`:processed` /
`:failed_permanent` / `:superseded`) is never processed again, but a crash after your
handler's side effects and before the ledger mark will re-invoke it on
redelivery. Write handlers idempotent, keyed on the external event
identity. `claim_delivery/3`, `mark_processed/4`,
`mark_failed/6`, `renew/4` and `reap/2` are public if you need to drive
the lease machine yourself (e.g. from your own async pipeline); the
sync pipeline used by the plug is the default.

Permanent failures need an operator-visible error record, rather than an endless
provider retry loop. `:superseded` identifies a retained legacy row replaced by
its canonical identity during a legacy identity adoption
(`AshHooks.Ingress.adopt_legacy_identity/3`); see [UPGRADING](../../UPGRADING.md).

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

  attributes do
    timestamps()
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

Add the outbound resources and emitter to that same domain:

```elixir
resources do
  resource(MyApp.WebhookLedger)
  resource(MyApp.WebhookEndpoint)
  resource(MyApp.WebhookSubscription)
  resource(MyApp.OutboundDelivery)
  resource(MyApp.Order)
  # ... your existing resources ...
end
```

Define a worker in your app (Oban must be in your dependencies):

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

The secret resolver maps an endpoint's secret reference to its value:
endpoints store references only, never secrets:

```elixir
defmodule MyApp.Secrets do
  # ref is whatever string you stored on the endpoint's secret_ref.
  # The value is a complete generated secret: create it once with
  # AshHooks.Signing.generate_secret/0 (returns a "whsec_"-prefixed,
  # correctly-encoded binary), store it whole in your secret store,
  # and return it unchanged:
  def webhook_secret("acme-main") do
    case System.fetch_env("ACME_WEBHOOK_SECRET") do
      {:ok, secret} -> {:ok, secret}
      :error -> {:error, :missing_secret}
    end
  end

  def webhook_secret(_unknown), do: {:error, :unknown_ref}
end
```

Oban itself (dependency, migration, and a supervised instance with a
`:webhooks` queue) is the consumer's to set up; see Oban's
[installation guide](https://hexdocs.pm/oban/installation.html); the worker above
plugs into it.

Set `PUBLIC_WEBHOOK_TEST_URL` to your existing public receiver endpoint and
`EXAMPLE_ORDER_ID` to the stable ID of the order-paid event you are sending.
Register an endpoint and a subscription, then dispatch:

```elixir
# a public, DNS-resolvable HTTPS URL: the send-time SSRF check
# resolves DNS and refuses private, loopback, and special-purpose targets
{:ok, endpoint} =
  Ash.create(MyApp.WebhookEndpoint, %{
    url: System.fetch_env!("PUBLIC_WEBHOOK_TEST_URL"),
    secret_ref: "acme-main"
  }, authorize?: false)

{:ok, _sub} =
  Ash.create(MyApp.WebhookSubscription, %{
    endpoint_id: endpoint.id,
    event_types: ["order_paid"]
  }, authorize?: false)

order_id = System.fetch_env!("EXAMPLE_ORDER_ID")

{:ok, event} =
  AshHooks.Event.new(
    type: :order_paid,
    payload: Jason.encode!(%{"order_id" => order_id}),
    # Reuse this ID when retrying the same logical order-paid event.
    id: "msg_order-" <> order_id
  )

{:ok, results} =
  AshHooks.dispatch(MyApp.Order, :order_paid, event,
    enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}
  )
```

With no `enqueue:` the rows persist `:pending` (durable ledger only,
nothing sends). With the worker seam wired, each row is delivered by
`AshHooks.Delivery`: Standard-Webhooks signed, retried with bounded
Retry-After and jittered backoff, dead-lettered at the ceiling, the
endpoint durably disabled on 410. A hostname that stops resolving is
transport, not a verdict: it retries labeled `nxdomain` (the name is
authoritatively gone) or `resolve_timeout` (resolver outage, congestion)
and only a validated private/loopback answer dead-letters immediately as
`unsafe_destination`: the labels a triage surface should key on.

Signing modes: `:standard` (default) needs only `secret_ref`. Both
`:legacy` and `:dual` require the endpoint to carry a
`legacy_secret_ref`: signing fails (and the row retries as
`signing_failed`) without one; `:dual` additionally emits the legacy
envelope alongside the Standard Webhooks one during receiver
migration.

**Fit the extensions to your domain** with per-resource options:
rename the exact-bytes column when your domain reserves `payload`
(`payload_attribute :event_bytes` in the delivery's `outbound_delivery`
block; the dispatch, signing, and send paths follow the configured name),
omit the retention destroy action on an append-only ledger
(`prune_action :none`: no destroy action exists, and
`AshHooks.Delivery.prune/2` fails loud), and map the durable
enable/disable onto your own switch (the endpoint's `endpoint do
status_attribute :active; enabled_values [true]; disabled_value false
end`: the dispatcher, the send path, and the 410 breaker all consult
YOUR attribute; the package injects no `status`). Generated primary
keys (`uuid_v7_primary_key`) compile as-is, and a subscription register
redeclared as a closed `{:array, :atom}` enum matches normally with
your own constraints. One obligation comes with the injected surface:
the generated write actions are yours to cover with action-specific policies,
or keep these resources off actor-facing surfaces. The resource module docs list
the full action set, including ownership binding, recovery claims, and pending
endpoint disable. Broad application update actions must not expose machine fields.

## Delivery logs and attempt history

Add the `AshHooks.OutboundAttempt` extension on its own resource (the
migration shape is above) and pass `attempts: MyApp.OutboundAttempt` to
`use AshHooks.Worker` (or the direct-run config): every delivery attempt
records one durable row with the time, outcome, classified reason, HTTP status,
latency in milliseconds, and the signing key REFERENCE (a secret-store
reference string, never secret material). Rows are idempotent per
`(delivery, attempt)`, and a history write failure never fails the send
(`[:ash_hooks, :attempt, :record_failed]` telemetry carries it).

Response capture stays OFF by default. To opt an endpoint in per row,
declare `response_capture_attributes :on` on the endpoint resource
(migrate the four columns) and set `response_capture: true` on rows that
should capture: the bytes are bounded by the row's
`response_capture_max_bytes`, pass the package's redaction floor, and
only response header names listed in `response_header_allowlist` are
kept.

Query both ledgers with keyset pagination (newest first):

```elixir
{:ok, %{records: deliveries, next_cursor: cursor}} =
  AshHooks.Delivery.list(MyApp.OutboundDelivery,
    endpoint_id: endpoint.id,
    status: [:succeeded, :dead_letter],
    from: DateTime.add(DateTime.utc_now(), -7, :day)
  )

{:ok, %{records: attempts}} =
  AshHooks.OutboundAttempt.list(MyApp.OutboundAttempt,
    endpoint_id: endpoint.id,
    outcome: [:failed_retryable, :dead_letter],
    after: cursor_of_previous_page
  )
```

**The full product surface** (each opt-in, each documented at its module):
attempt history and delivery-log queries (above), resend and bulk replay
(`AshHooks.Delivery.resend/2` / `replay/2`), test sends
(`AshHooks.Delivery.test_send/2`), secret rolling
(`AshHooks.Endpoint.roll_secret/2` with the Standard Webhooks
multi-signature overlap), endpoint health and the sustained-failure
auto-disable (`AshHooks.EndpointHealth`), the event catalog and
payload-version pinning (`AshHooks.Catalog`), subscription attribute
filters (`filter_attributes`), the event log
(`AshHooks.OutboundEvent`), the delivery transport behavior
(`AshHooks.Transport`), inbound parity
(`AshHooks.Ingress.list/2` / `counts/2`, `previous_secret`, `paused`),
and the send-time destination policy seam
(`AshHooks.DestinationPolicy`).

Response snippets store NO body bytes by default (a status +
content-type summary). For a one-row diagnostic capture, re-drive the
row with `AshHooks.Delivery.run/2`; it takes the same configuration
the worker macro bakes (deliveries, endpoints, secret_resolver, retry
policy) plus the per-call `snippet_capture: true`; the
[guided-tour Livebook](../livebooks/get-started.livemd) shows a worked
config. The captured body persists only after passing the package's
redaction, marked `[captured]`.

The direct driver uses the same retry defaults as the worker. When copying a
custom retry policy, map the worker's `delivery_max_attempts` to the driver's
`max_attempts`; the other retry option names stay the same. Copy the complete
policy for a diagnostic run. A lower delivery ceiling can dead-letter a row
that the worker would still retry.

### Keep delivery moving after a crash

Schedule recovery alongside the worker. It reconnects a durable row to its queue
after a crash between persistence and enqueue, a discarded job, or an expired
send lease. Run it for each outbound declaration and tenant:

```elixir
AshHooks.reconcile_pending(MyApp.Order, :order_paid,
  enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}
)
```

The declaration and queue route must match the stored row. Recovery preserves
attempt counts and future retry times; it also completes a pending 410 disable
without sending again. Named worker callbacks provide a stable route. If you use
an anonymous enqueue callback, supply a stable `enqueue_key` at dispatch and recovery.
Synchronize application-node clocks because leases use application UTC time.

The ledger fences each attempt's result, while network delivery remains
at-least-once. A receiver can accept a request before the sender dies, so deduplicate
by `webhook-id` at the receiver. Upgrading an existing installation? Follow
[UPGRADING](../../UPGRADING.md) from your release onward before you start workers.

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

`attach_many` with the exact names is required: `:telemetry.execute/3`
matches exact names only. Events carry ids, integers, fixed atoms, and
classified reasons, never secrets, bodies, or payloads (ADR-0005).

## Where next

- [Multi-tenant adoption checklist](tenancy-adoption-checklist.md): when one
  app serves many organizations
- [Guided tour (Livebook)](../livebooks/get-started.livemd): run the whole
  library inside one notebook
- `AshHooks.Dispatcher`, `AshHooks.Delivery`, and `AshHooks.Ingress`
  module docs: the machines this walkthrough drove
