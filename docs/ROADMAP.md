# Roadmap

ash_hooks supplies verified inbound webhooks and signed, durable outbound delivery for
Ash applications. Hosts own their resources, policies, keys, and scheduling.

This is the open work, in order. Each row is done when its acceptance holds on `main`
and its change is in the `CHANGELOG.md` section of the release that ships it.

## Queue

| Outcome | Acceptance | Waits on |
|---|---|---|
| W27: Publish transactionally and select subscriptions in the query for every host and tenant. | One-statement outbox acceptance, fenced fanout, per-tenant recovery, SQL type/pause/filter selection with an Elixir guard, and the ADR 0029 acceptance matrix pass in hosted CI. | 3.3.0 ships first; implementation for 3.4.0. |
| Every code block in the shipped documentation is either run or says why not. | Each block in the guides, the API docs, the Livebooks and the generated DSL docs carries a disposition: the name of the test that executes it in the same run, or a specific reason it is not run. A block that is unmarked, has no executing run or has an empty reason fails the documentation check. Shipped Elixir blocks are formatted as `mix format` writes them. | Nothing; in progress. |
| Releases record the commit and archive they publish. | `docs/PUBLISHING.md` states the invariant: a version is published from the `main` commit whose complete CI run passed, from a clean checkout of that commit, and its GitHub Release records that commit and the SHA-256 of the archive `scripts/check-package.sh` built. | Nothing; in progress. |
| UPGRADING gives the replacement configuration for each vendor module removed in 3.0.0. | Each of the 13 removed modules has a replacement block in `UPGRADING.md`, checked by the same tests that cover the scheme recipes, so the `CHANGELOG.md` 3.0.0 entry that promises them is true. | The documentation disposition check above. |
| Hosts can extend inbound and outbound handling with the full delivery context. | Inbound: a verifier can record the facts it verified on the ledger row. Outbound: a request signer receives the endpoint, the tenant and the attempt, so a host can sign each request per endpoint (for example with RFC 9421 HTTP Message Signatures). Each seam has a decision record, a guide section and tests. | A design decision, recorded as an ADR before the build. |
| The synchronous-decision tutorial links a signed authorization recipe. | The "Decide in the response" section of `documentation/tutorials/verify-any-sender.md` links `request_seal`'s signed authorization hook recipe. | `request_seal` 2.0.0, which publishes that recipe. |
| CI checks follow one shape. | One `checks` job runs compile warnings, formatting and Credo; `test` runs the tests; `dialyzer` and `security` keep their names; the aggregate job requires all of them. | Nothing. |
| Committed lock files are exactly what Mix writes. | CI checks `mix.lock` and every committed lock fixture, and fails on a hand edit that `mix deps.get --check-locked` would admit. | The CI job shape above. |
| CI scans pushed commits for secrets. | The `security` job runs gitleaks with `.gitleaks.toml` over the pushed range and fails on a finding. | The CI job shape above. |

## Not planned

| Proposal | Why not |
|---|---|
| A configurable retry ladder, or attempt records written only for failures. | Retry policy is the delivery row's: capped exponential backoff with jitter, `Retry-After` handling, and `retryable_statuses` to choose which HTTP failures retry ([ADR 0008](adr/0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md)). `AshHooks.OutboundAttempt` already records every attempt. No adopter needs a separate ladder. |
| Outbound batches that carry several events in one message. | One message carries one event, with one `webhook-id`, one retry history and one receiver deduplication key ([ADR 0008](adr/0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md)). A batch would share one id and one retry fate across unrelated events. |
| Verifying signed responses to settle usage or billing. | Delivery succeeds on the receiver's status code. A signed response that settles usage is an application protocol between the host and its receiver. The host can build it in its own code; it does not belong in the webhook delivery contract. |
