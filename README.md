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
> signing/verification with byte-identical legacy `:dual` mode, and the
> inbound sync pipeline — raw-body verify → unique-ingest fenced ledger
> (`AshHooks.InboundDelivery` extension + `AshHooks.Ingress`) with claim/lease
> fencing, a reaper, and fail-closed DSL verifiers. Upcoming slices: vendor
> verifiers (ComplyCube, HubSpot), the async (202) delivery runtime, outbound
> delivery tracking, and telemetry — tracked by
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
the exact wire bytes, and a router plug cannot recover pre-parser bytes.

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
  inbound :complycube do
    secret {:app_env, [:my_app, :complycube_secret]}
  end
end

outbound :order_paid do
  signing_mode :standard
end
```

Inbound (sync mode) — a controller reads the cached raw body and drives the
fenced machine:

```elixir
AshHooks.Ingress.ingest(Ledger, :complycube, conn.private[:ash_hooks_raw_body], %{
  signature: get_req_header(conn, "x-signature") |> List.first(),
  headers: get_req_header(conn) |> Map.new(),
  scope: %{account_id: connection.account_id}
})
```

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
