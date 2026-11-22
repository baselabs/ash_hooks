# Roadmap

ash_hooks supplies verified inbound webhooks and signed, durable outbound delivery for
Ash applications. Hosts own their resources, policies, keys, and scheduling.

This is the open work, in order. Each row is done when its acceptance holds on `main`
and its change is in the `CHANGELOG.md` section of the release that ships it.

## Queue

| Outcome | Acceptance | Waits on |
|---|---|---|
| W33: Hosts send buffered and streaming HTTP requests through public pinned egress. | `AshHooks.Egress` and the optional Req adapter pass hosted CI: TLS identity, mixed DNS answers, redirect refusal, one attempt under installed retry functions, exact sent classification, and contents-free telemetry ([ADR 0031](adr/0031-pinned-egress.md)). | 3.6.0. |
| The synchronous-decision tutorial links a signed authorization recipe. | The "Decide in the response" section of `documentation/tutorials/verify-any-sender.md` links `request_seal`'s signed authorization hook recipe. | `request_seal` 2.0.0, which publishes that recipe. |

## Not planned

| Proposal | Why not |
|---|---|
| A configurable retry ladder, or attempt records written only for failures. | Retry policy is the delivery row's: capped exponential backoff with jitter, `Retry-After` handling, and `retryable_statuses` to choose which HTTP failures retry ([ADR 0008](adr/0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md)). `AshHooks.OutboundAttempt` already records every attempt. No adopter needs a separate ladder. |
| Outbound batches that carry several events in one message. | One message carries one event, with one `webhook-id`, one retry history and one receiver deduplication key ([ADR 0008](adr/0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md)). A batch would share one id and one retry fate across unrelated events. |
| Verifying signed responses to settle usage or billing. | Delivery succeeds on the receiver's status code. A signed response that settles usage is an application protocol between the host and its receiver. The host can build it in its own code; it does not belong in the webhook delivery contract. |
