# AshHooks

[![Hex.pm](https://img.shields.io/hexpm/v/ash_hooks.svg)](https://hex.pm/packages/ash_hooks)

Webhooks for [Ash Framework](https://ash-hq.org) — **inbound** (receive, verify
per-provider signatures, deduplicate, emit domain events) and **outbound**
(sign, deliver, retry, track).

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

## Usage

Attach to a resource and declare sources and events:

```elixir
use Ash.Resource, extensions: [AshHooks]

webhooks do
  inbound :complycube do
    secret {:app_env, [:my_app, :complycube_secret]}
  end

  outbound :order_paid do
    signing_mode :standard
  end
end
```

Outbound deliveries are signed per the [Standard Webhooks](https://www.standardwebhooks.com)
specification (`webhook-id` / `webhook-timestamp` / `webhook-signature`, `v1`
HMAC-SHA256 and `v1a` ed25519), so receivers verify with any conformant
library. A `:dual` mode additionally emits a legacy envelope during receiver
migration.

## Design records

Architectural decisions live in [`docs/adr/`](docs/adr/).

## License

MIT.
