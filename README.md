# AshHooks

[![Hex.pm](https://img.shields.io/hexpm/v/ash_hooks.svg)](https://hex.pm/packages/ash_hooks)

Webhooks for [Ash Framework](https://ash-hq.org) — **inbound** (receive, verify
per-provider signatures, deduplicate, emit domain events) and **outbound**
(sign, deliver, retry, track).

> **Status: provider behaviour + SW signing + inbound ingress/fenced ledger.**
> Landed: the DSL sections and install task (including the endpoint
> `body_reader` codemod), the CI compile-matrix with the Oban/plug-free proof
> (ADR-0004), the inbound provider contract (`AshHooks.Provider` with
> `default_verify_signature/4`, the `AshHooks.Provider.Mock` reference
> provider, the splode error hierarchy), Standard Webhooks `v1`+`v1a`
> signing/verification with byte-identical legacy `:dual` mode, the inbound
> sync pipeline — raw-body verify → unique-ingest fenced ledger
> (`AshHooks.InboundDelivery` extension + `AshHooks.Ingress`) with claim/lease
> fencing, a reaper, and fail-closed DSL verifiers — and the vendor
> verifiers `AshHooks.Provider.ComplyCube` (raw-body HMAC-SHA256 over the
> `ComplyCube-Signature` header, SDK-vector conformance) and
> `AshHooks.Provider.HubSpotV3` (composite `method + requestUri + body +
> timestamp` HMAC over a separate millisecond timestamp header, batch
> array bodies, docs-vector conformance). Upcoming slices: the async (202)
> delivery runtime, outbound delivery tracking, and telemetry — tracked by
> [#1](https://github.com/baselabs/ash_hooks/issues/1).

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
HMAC-SHA256 and `v1a` ed25519), so receivers verify with any conformant
library; a `:dual` mode additionally emits a byte-identical legacy envelope
during receiver migration. Durable delivery with retry/backoff lands with the
delivery-runtime slices.

## Design records

Architectural decisions live in [`docs/adr/`](docs/adr/).

## License

MIT.
