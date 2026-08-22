# AshHooks

[![Hex.pm](https://img.shields.io/hexpm/v/ash_hooks.svg)](https://hex.pm/packages/ash_hooks)

Webhooks for [Ash Framework](https://ash-hq.org) — **inbound** (receive, verify
per-provider signatures, deduplicate, emit domain events) and **outbound**
(sign, deliver, retry, track).

> **Status: v0.1.0 — inbound + outbound complete.**
> Inbound: per-provider signature verification (`AshHooks.Provider`
> behaviour; ComplyCube + HubSpot v3 reference providers), a fenced
> unique-ingest ledger with claim/lease fencing and a reaper, and
> fail-closed DSL verifiers. Outbound: `AshHooks.dispatch/4` fanout with
> per-endpoint isolation, the delivery runtime on Oban
> (`use AshHooks.Worker`) with row-owned retry policy, Standard Webhooks
> signing (v1/v1a, legacy `:dual` migration mode), and a memory-bounded
> native HTTP adapter. Security floors ship in the package (ADR-0005):
> secrets as sources only, SSRF guards at registration + send, response
> snippets store no body bytes by default. Telemetry events for the
> whole lifecycle (see `AshHooks.Telemetry`). Design records:
> [#1](https://github.com/baselabs/ash_hooks/issues/1),
> ADR-0001–0008.

Inbound and outbound are independently consumable: inbound-only applications
pull no queue infrastructure.

## Installation

```elixir
def deps do
  [
    {:ash_hooks, "~> 0.1.0"}
  ]
end
```

Or with [igniter](https://hex.pm/packages/igniter):

```
mix igniter.install ash_hooks
```

The installer also patches your endpoint's `Plug.Parsers` with
`body_reader: {AshHooks.BodyReader, :read_body, []}` — signature schemes sign
the exact wire bytes, and a router plug cannot recover pre-parser bytes. By
default every parsed request carries a cached copy of its raw body; pass
`[only: ["/webhooks"]]` as the reader's third element to scope that memory
cost to the webhook routes.

## Usage

Attach to a resource and declare sources and events:

```elixir
use Ash.Resource,
  data_layer: AshSqlite.DataLayer,
  extensions: [AshHooks, AshHooks.InboundDelivery]

inbound_delivery do
  # provider event ids are not globally unique across accounts — the
  # unique-ingest identity extends by your scope slots
  scope_identity([:account_id])
end

webhooks do
  # convention-resolves to AshHooks.Provider.ComplyCube
  inbound :comply_cube do
    secret {:app_env, [:my_app, :complycube_secret]}
  end

  # convention-resolves to AshHooks.Provider.HubSpotV3 — the vendor's
  # five-minute replay window applies by default; replay_window_seconds
  # overrides it in either direction
  inbound :hub_spot_v3 do
    secret {:app_env, [:my_app, :hubspot_client_secret]}
  end

  outbound :order_paid do
    signing_mode :standard
  end
end
```

Inbound (sync mode) — a controller reads the cached raw body and drives the
fenced machine:

```elixir
AshHooks.Ingress.ingest(Ledger, :comply_cube, conn.private[:ash_hooks_raw_body], %{
  signature: get_req_header(conn, "complycube-signature") |> List.first(),
  headers: Map.new(conn.req_headers),
  scope: %{account_id: connection.account_id}
})
```

HubSpot's v3 scheme signs the method and the full request URI alongside the
body, so its controller passes both. Reconstruct the public URI — Plug's
`conn.query_string` excludes the `?` and `conn.host` excludes a non-default
port, so join explicitly (and behind any TLS-terminating proxy use the host
HubSpot actually called):

```elixir
query = if conn.query_string == "", do: "", else: "?" <> conn.query_string

AshHooks.Ingress.ingest(Ledger, :hub_spot_v3, conn.private[:ash_hooks_raw_body], %{
  signature: get_req_header(conn, "x-hubspot-signature-v3") |> List.first(),
  headers: Map.new(conn.req_headers),
  method: conn.method,
  request_uri: "https://" <> conn.host <> conn.request_path <> query
})
```

HubSpot delivers batches — a top-level JSON array of event objects. The
ledger stores the array verbatim; a homogeneous batch parses to its
subscription type (`contact.creation` → `:contact_creation`), a mixed batch
to `:mixed` (fan out per event in your handler), and an undocumented
subscription type fails closed into the ledger as `failed_permanent`
(`unknown_event_type`) — recorded and auditable.

The machine persists the raw payload before handling, deduplicates on
storage-level uniqueness (exactly one `:created` per delivery, concurrent or
sequential), and fences claims with a monotonic token and an expiring lease —
a crash between any two steps re-drives on redelivery instead of silently
dropping, and a stale owner (superseded or expired lease) can never mark.
Handler outcomes land in the ledger (`:processed`,
`:failed_retryable`, `:failed_permanent`); expired leases are re-driven by
`AshHooks.Ingress.reap/1`.

Outbound deliveries are signed per the [Standard Webhooks](https://www.standardwebhooks.com)
specification (`webhook-id` / `webhook-timestamp` / `webhook-signature`, `v1`
HMAC-SHA256 and `v1a` ed25519 — old+new key rotation on both schemes), so
receivers verify with any conformant library; a `:dual` mode additionally
emits a byte-identical legacy envelope during receiver migration.

Outbound fanout (landed): declare the Subscription / Endpoint /
OutboundDelivery resources on your data layer, point the outbound
declaration at them, and dispatch:

```elixir
defmodule MyApp.WebhookEndpoint do
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer,
    domain: MyApp,
    extensions: [AshHooks.Endpoint]

  sqlite do
    table("webhook_endpoints")
    repo(MyApp.Repo)
  end

  actions do
    defaults([:read, :create, :update])
  end
end

defmodule MyApp.WebhookSubscription do
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer,
    domain: MyApp,
    extensions: [AshHooks.Subscription]

  sqlite do
    table("webhook_subscriptions")
    repo(MyApp.Repo)
  end

  actions do
    defaults([:read, :create])
  end

  subscription do
    endpoint_resource(MyApp.WebhookEndpoint)
  end
end

defmodule MyApp.OutboundDelivery do
  use Ash.Resource,
    data_layer: AshSqlite.DataLayer,
    domain: MyApp,
    extensions: [AshHooks.OutboundDelivery]

  sqlite do
    table("outbound_deliveries")
    repo(MyApp.Repo)
  end

  actions do
    defaults([:read])
  end
end
```

```elixir
webhooks do
  outbound :order_paid do
    subscriptions(MyApp.WebhookSubscription)
    deliveries(MyApp.OutboundDelivery)
  end
end
```

```elixir
{:ok, event} =
  AshHooks.Event.new(type: :order_paid, payload: Jason.encode!(order))

AshHooks.dispatch(Order, :order_paid, event)
```

Each matching enabled endpoint gets a durable delivery row unique on
`{endpoint_id, event_uuid}` — the same pair the Oban job uniqueness keys
use — carrying the exact payload bytes to sign and the frozen effective
signing mode. Endpoints store secret REFERENCES only (`whsec_`-shaped
literals are rejected at cast, on every write path); endpoints carry a
durable `:enabled | :disabled` state the dispatcher respects. One
endpoint's enqueue failure records `:enqueue_failed` on its row and never
stops its siblings; a re-dispatch claims the failed row via a CAS and
retries the enqueue exactly once per won claim. With no `:enqueue`
configured, rows persist `:pending` (`:deferred` results).

Delivery runtime (landed): define ONE worker module in your app and wire
it as the dispatch enqueuer —

```elixir
defmodule MyApp.WebhookDeliveryWorker do
  use AshHooks.Worker,
    deliveries: MyApp.OutboundDelivery,
    endpoints: MyApp.WebhookEndpoint,
    secret_resolver: {MyApp.Secrets, :webhook_secret},
    queue: :webhooks
end

AshHooks.dispatch(Order, :order_paid, event,
  enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}
)
```

The worker drives `AshHooks.Delivery` (ADR-0008: the ROW owns the retry
policy — attempts, `next_attempt_at`, the dead-letter ceiling — and Oban
is the durable trigger). Sends are Standard-Webhooks signed per the row's
mode with the same `webhook-id` on every retry; only 2xx succeeds;
redirects are never followed; 410 disables the endpoint durably;
408/429 honor `Retry-After` (bounded); 5xx/transport failures back off
exponentially with jitter; other 4xx and refused redirects dead-letter
immediately. Response snippets store NO body bytes by default — a fixed
summary of the status and an allowlisted content-type token (ADR-0005's
snippet amendment); a per-call `snippet_capture: true` in the
`AshHooks.Delivery.run/2` config opts one diagnostic run into body
capture, which persists the `[captured]`-marked body under the package
floor (NFKC homoglyph folding, a bounded-fixpoint decode chain,
separator-tolerant marker patterns, and a ≥16-char union-alphabet
entropy rule) with an optional fail-closed `snippet_redactor` callback
ahead of it. Machine-written fields
accept no action input. SSRF is guarded at registration (the endpoint's
`url` type rejects private/loopback/link-local/metadata literals and
non-http schemes on every write path) and re-checked at send with DNS
re-resolution. HTTP goes through the `AshHooks.Http` adapter behaviour —
the default is `AshHooks.Http.Bounded`, a minimal HTTP/1.1 client whose
EVERY read is capped (headers, and bodies under Content-Length, chunked,
and read-to-close framings alike — no response can balloon a worker's
memory); `AshHooks.Http.Httpc` (OTP `:httpc`) is available as an
alternative, and you can inject your own for tests or proxies. The package
still compiles and runs Oban-free (CI no-optional leg + the inbound-only
proof); `use AshHooks.Worker` without Oban on the host fails
deterministically at compile.

### Dispatch-time capture (consumer-owned, no package change)

`snippet_capture` is deliberately a per-call runtime config key, not a
worker-macro knob — but dispatch-time opt-in needs no contract change:
bring your own enqueue seam and your own Oban worker driving the public
runtime with the flag merged in.

```elixir
defmodule MyApp.CaptureWorker do
  use Oban.Worker, queue: :webhook_diagnostics

  def perform(%Oban.Job{args: args}) do
    AshHooks.Delivery.run(args,
      deliveries: MyApp.OutboundDelivery,
      endpoints: MyApp.WebhookEndpoint,
      secret_resolver: {MyApp.Secrets, :webhook_secret},
      snippet_capture: true
    )
  end
end

# the enqueue seam contract is (delivery, event) -> :ok | {:error, term}
AshHooks.dispatch(Order, :order_paid, event,
  enqueue: fn delivery, _event ->
    %{ "endpoint_id" => to_string(delivery.endpoint_id),
       "event_uuid" => delivery.event_uuid }
    |> MyApp.CaptureWorker.new()
    |> Oban.insert()
    |> case do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
)
```

For a one-row diagnostic re-drive of an already-dispatched event, call
`AshHooks.Delivery.run/2` directly with `snippet_capture: true` — the
row's `{endpoint_id, event_uuid}` args and your config are all it takes.

## Observability

Every lifecycle transition emits a telemetry event — ingress
verify/dedup/claim, dispatch enqueue-failure, delivery
attempt/result/backoff/dead-letter/endpoint-disable. Events carry ids,
integers, fixed-vocabulary atoms, and classified reason strings only —
never secrets, bodies, or payloads (ADR-0005), so they are safe to ship
to any metrics/APM backend. `:telemetry.execute/3` matches exact event
names, so consume the surface with one `attach_many` — the full list
and a copy-paste handler live in `AshHooks.Telemetry`'s docs and the
[get-started tutorial](https://github.com/baselabs/ash_hooks/blob/main/documentation/tutorials/get-started.md).

## Design records

Architectural decisions live in
[`docs/adr/`](https://github.com/baselabs/ash_hooks/tree/main/docs/adr).

## License

MIT.
