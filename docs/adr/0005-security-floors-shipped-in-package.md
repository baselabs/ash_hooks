# ADR-0005 — Security defaults and application boundaries

- **Status:** Accepted August 20, 2026; response capture and read-policy boundaries
  amended August 22, 2026; reconciled for 2.0 on October 6, 2026.
- **Deciders:** Maintainer; independent adversarial design review.

## Context

Webhook requests carry untrusted bytes across authentication, storage, and HTTP
boundaries. The library can enforce signature checks, destination validation,
transport bounds, and redaction. An application's actor model, secret custody,
and business effects require application-owned policies and integrations.

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
- Persist endpoint disablement following 410 responses. Version 2.0 first records
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
