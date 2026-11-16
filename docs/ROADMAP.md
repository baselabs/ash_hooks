# Roadmap

ash_hooks supplies verified inbound webhooks and signed, durable outbound delivery for
Ash applications. Hosts own their resources, policies, keys, and scheduling.

## Queue

| ID | Outcome | Acceptance | Waits on |
|---|---|---|---|
| HOOKS-SYNC-DECISION-RECIPE | A host that must answer a sender synchronously can verify any sender's signature and decide in the response. | A tutorial shows `AshHooks.Signing.verify/4` in the host's own Plug without the ingress pipeline, returns the decision in the response with no ledger row and no vendor named, states that the response is not authenticated, links `request_seal`'s signed authorization hook recipe, and runs in the documentation gate. | `request_seal` 2.0.0 for the link |
| HOOKS-RELEASE-ORDER | Every check runs on the landing commit before the tag, and the tag and release come last. | The publishing guide follows the approved order; a tag ruleset protects `v*`; the named-lock fixture proves a consumer resolves the published lock. | the organization release App |
