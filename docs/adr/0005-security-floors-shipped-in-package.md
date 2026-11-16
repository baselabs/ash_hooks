# 0005 - Security defaults and application boundaries

## Context

Webhook bytes cross untrusted authentication, storage, and HTTP boundaries.
The library enforces its checks; hosts own policies, custody, and business effects.

## Decision

The supplied implementation uses restrictive defaults for the boundaries it owns:

- Verify inbound signatures over the exact raw body before decoding and handling.
  Missing secrets or request bytes fail closed.
- Accept secret sources in the inbound DSL rather than literal secret values.
  Endpoint rows store secret references; their type rejects known signing-material
  prefixes. Applications resolve and protect the actual secret values.
- Keep request headers out of the ledgers. Inbound rows retain decoded payloads
  and signed-body digests; outbound rows retain exact payload bytes.
- Store response status and an allowlisted content-type summary by default.
  Explicit diagnostic capture is bounded and redacted before persistence. An
  optional application redactor runs first; failure leaves the body uncaptured.
- Emit telemetry identifiers, measurements, states, and classified reasons rather
  than payloads or resolved secrets. The optional fingerprint helper is for
  application correlation; package events do not emit it.
- Validate endpoint URLs at registration without hostname DNS. Resolve and check
  destinations at send time, then connect to a validated address. Both supplied
  adapters preserve the original host for HTTP and TLS. See [ADR-0009](0009-bounded-http-default-and-ssrf-pinning.md).
- Persist endpoint disablement following 410 responses. The driver first records
  the obligation and endpoint snapshot; recovery finishes it without resending or
  disabling a replacement configuration. See [ADR-0012](0012-durable-delivery-ownership-and-recovery.md).

Applications define read policies and protect generated machine actions. The
package does not inject an authorizer or policy based on an assumed actor model.
Internal state transitions use `authorize?: false`; exposing those functions or
resources to application callers requires an application authorization boundary.
The README and tutorial include policy guidance.

## Consequences

Applications own migrations, secret storage, actor policies, idempotent business
actions, scheduling, and retention. Deleting terminal rows reopens their delivery
identity, so retention must account for the provider's replay horizon and the
producer's re-emission horizon. Stored payloads can contain personal information;
read policies and payload redaction remain part of application operation.

Explicit adapter, destination-validation, and bound overrides replace the relevant
built-in behavior. Applications using them must preserve the required security
properties for their deployment.

## Signature parsing boundary

[Signature.jws/3](../../lib/ash_hooks/provider/signature.ex) parses compact
segments and the protected header before authentication. The host pins the
algorithm; unsupported critical headers and unencoded payloads are refused.
Key-location headers supply no keys. Verification authenticates the exact
encoded `header.payload` input before time claims and delivered payloads are used.
The ledger's `json_decoder` supplies the protected-header, claim, and delivered
JSON decoder. Explicit formats and provider decoders follow
[the decoding decision](0016-inbound-json-decoding-policy.md).
Ingress calls event parsing, identity callbacks, and handlers only after verification.
