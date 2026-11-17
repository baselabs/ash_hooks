# Destination policies, transports, and endpoint health

Continue the resources and migrations in [event recovery](outbound-recovery.md)
and [catalogs and filters](outbound-contracts.md). This guide sends real HTTP
requests. Use a controlled receiver and signing secret; do not log that secret.

## Keep destination policy and transport decisions explicit

This policy admits normal HTTPS destinations to the package's public-address
check. It denies other schemes. The transport implements the native
`c:AshHooks.Transport.request/5` contract and applies an application timeout while
retaining the bounded adapter's DNS validation, TLS, connection pinning, and
response limits. Replace its body with your own protocol when adopting another
transport, preserving the same result contract.

<!-- tested: operations-transport -->
```elixir
defmodule MyApp.WebhookNetwork do
  @behaviour AshHooks.DestinationPolicy
  @behaviour AshHooks.Transport

  @impl AshHooks.DestinationPolicy
  def check("https://" <> _rest, _context), do: :default
  def check(_url, _context), do: :deny

  def transport(_endpoint, _tenant), do: __MODULE__

  @impl AshHooks.Transport
  def request(method, url, headers, body, opts) do
    AshHooks.Http.Bounded.request(method, url, headers, body,
      Keyword.put(opts, :timeout, 5_000))
  end
end
```

Wire both callbacks into the worker macro, or use this direct-run configuration.
It runs the `delivery` from the catalog example and records real attempt history:

<!-- tested: operations-send -->
```elixir
run_config = [
  deliveries: MyApp.OutboundDelivery,
  endpoints: MyApp.WebhookEndpoint,
  attempts: MyApp.OutboundAttempt,
  secret_resolver: {MyApp.Secrets, :webhook_secret},
  destination_policy: {MyApp.WebhookNetwork, :check},
  transport: {MyApp.WebhookNetwork, :transport}
]
:ok = AshHooks.Delivery.run(%{"delivery_pk" => AshHooks.PrimaryKey.encode(delivery)}, run_config)
sent_delivery = Ash.get!(MyApp.OutboundDelivery, delivery.id, authorize?: false)
```

A policy receives `endpoint_id` and `tenant`. `:deny` dead-letters without sending;
`:default` runs the package's public-address gate. `:allow` bypasses that gate,
so reserve it for an explicit application trust decision. The HTTP adapter's own
address validation still applies. A non-HTTP transport must enforce its own
connection boundary. Keep validation enabled for untrusted destinations.

A policy exception or invalid result retries as `destination_policy_failed`.
A resolver exception or invalid transport retries as `transport_resolution`;
it does not silently fall back to HTTP. The runtime classifies transport results:
2xx succeeds, 408/429/5xx and transport errors retry, redirects are refused,
other 4xx dead-letter, and 410 records the endpoint-disable obligation. The runner returns `:ok` after recording the outcome, or a snooze/error when
execution cannot finish. Read the persisted delivery to inspect `status` and
`last_error`.

## Migrate and configure sustained-failure disablement

Merge this into the endpoint section beside `version_pinning :on`:

<!-- tested: operations-health-options -->
```elixir
endpoint do
  auto_disable do
    failure_window_seconds 3_600
    failure_share 0.95
    min_attempts 10
    warning_interval_seconds 120
  end
end
```

Add the marker column before deploying that declaration:

<!-- tested: operations-migration -->
```elixir
alter table(:webhook_endpoints) do
  add :disable_warned_at, :utc_datetime_usec
end
```

Query health and schedule sweeps through trusted application code:

<!-- tested: operations-health -->
```elixir
{:ok, health} = AshHooks.EndpointHealth.stats(MyApp.OutboundAttempt,
  endpoint_id: endpoint.id, window_seconds: 3_600)

sweep_result = AshHooks.EndpointHealth.sweep(MyApp.WebhookEndpoint, MyApp.OutboundAttempt)

case sweep_result do
  {:ok, %{unread: 0} = counts} -> {:complete, counts}
  {:ok, counts} -> {:retry_storage, counts}
  {:error, reason} -> {:retry_storage, reason}
end
```

Schedule a sweep per tenant, passing `tenant:` to both health calls, the worker,
and direct runner. A qualifying endpoint first gets a persisted warning marker
and `[:ash_hooks, :endpoint, :disable_warning]` telemetry. Sustained failures can
disable it only after the full 120 seconds, including overlapping sweeps. The
application owns scheduling and operator notification. Observe disable telemetry
with reason `:sustained_failure`; an endpoint below the warning band clears its
marker. A failed history read emits `[:ash_hooks, :endpoint_health, :read_failed]`
and increments `unread`, preserving that endpoint's status and warning marker.
An endpoint-list read failure returns an error. Sweep counts describe committed
writes and unread histories; a positive `unread` count means an incomplete sweep. Repair storage
and retry. Persisted warning times preserve the interval.

After investigating and repairing a disabled receiver, authorize an operator and
use the application's endpoint update action to set `status: :enabled`. The
package never reenables it automatically. Pending sends check current endpoint
state; rearm terminal deliveries with `Delivery.resend/2` or the retained-event
replay in the recovery guide. Protect disable, reenable, replay, and history reads
with application policies. Prune attempt history only after the window needed
for health and incident investigation.
