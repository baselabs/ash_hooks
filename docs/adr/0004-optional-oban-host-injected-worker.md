# 0004: Optional Oban and host-injected workers

Status: Accepted August 20, 2026; amended November 15, 2026.

## Decision

Oban is optional. `use AshHooks.Worker` expands `use Oban.Worker` inside the host
application and delegates jobs to the concrete `AshHooks.Delivery.run/2` driver.
The package compiles and runs without Oban. Generating an `AshHooks.Worker`
requires Oban. The host owns its worker, queue configuration, and scheduling.
Runnable-job admission follows
[the ownership decision](0012-durable-delivery-ownership-and-recovery.md).

## Consequences

- Inbound needs no queue. Outbound applications can define a worker or schedule
  delivery themselves with `AshHooks.Delivery.run/2`.
- The delivery driver is concrete while HTTP, provider, custody, and transport
  contracts are public behaviors. See the
  [custody decision](0013-key-custody-issuance-and-durable-disposal.md) and
  [host configuration decision](0021-host-trust-boundaries-and-subscription-selection.md).
