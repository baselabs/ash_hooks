# 0025 - Inbound handler results

## Context

After verification and dedup (ADR 0003, ADR 0007), ingress calls the provider's
`handle_event`. The result decides whether the receipt is finished, failed for good
or tried again. Hosts write these handlers, so ingress must give a defined outcome
for every result, including results outside the callback's contract.

## Decision

Ingress classifies the handler result and records it under the claim's fencing
token:

| Handler result | Recorded state | Error class |
|---|---|---|
| `{:ok, value}` for any value | processed | none |
| `{:error, :permanent, term}` | failed, permanent | from `term` |
| `{:error, :retry, term}` | failed, retryable | from `term` |
| an event type the provider does not know | failed, permanent | `unknown_event_type` |
| a payload the provider cannot parse | failed, permanent | `malformed_payload` |
| the handler raises, exits or throws | failed, retryable | `handler_crashed` |
| any other value | failed, retryable | `invalid_handler_result` |

Every `{:ok, value}` remains a success, including maps, scalars and nil, as
required by the 3.x compatibility contract (ADR 0010). A bare `:ok`, a two-element
`{:error, term}` or any other unrecognized result is a host programming error. It
is recorded as a retryable failure, like a crash, rather than being left claimed
until its lease expires or crashing the request. Every recorded failure emits the ingress
telemetry for its class.

A failed fenced write (`:stale_token`) means another owner holds the receipt. In
that case ingress reloads the row and returns its state, and records nothing.

## Consequences

Every receipt that reaches a handler leaves that call in a recorded state, with a
class a host can query and alert on. A retryable failure runs the handler again on
recovery, so a handler with side effects must be safe to run more than once. A
crash after the effect and before the record can repeat the effect (ADR 0003).
