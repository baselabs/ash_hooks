# 0004 - Optional Oban and host-injected workers

## Decision

Oban is optional. `use AshHooks.Worker` expands `use Oban.Worker` inside the host
application and delegates jobs to the concrete `AshHooks.Delivery.run/2` driver.
The package compiles and runs without Oban. Selecting queue delivery without
Oban fails before accepting delivery work. The host owns its worker, queue
configuration, and scheduling. Runnable-job admission follows
[the ownership decision](0012-durable-delivery-ownership-and-recovery.md).

## Consequences

- Inbound-only applications need no queue; outbound applications define a worker.
- The delivery driver is concrete while HTTP, provider, custody, and transport
  contracts are public behaviors. See the
  [custody decision](0013-key-custody-issuance-and-durable-disposal.md) and
  [host configuration decision](0021-host-trust-boundaries-and-subscription-selection.md).
