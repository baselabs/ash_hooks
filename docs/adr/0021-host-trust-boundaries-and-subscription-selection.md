# 0021: Host trust boundaries and subscription selection

Status: Accepted November 15, 2026; amended November 17, 2026.

## Context

Hosts control transport, destination, timing, and payload policies.
Untrusted requests and subscription data must not choose those trust boundaries.

## Decision

[Worker](../../lib/ash_hooks/worker.ex) and direct
[Delivery](../../lib/ash_hooks/delivery.ex) configuration expose these policies:

- A per-endpoint transport resolver returns an `AshHooks.Transport` module
  or `nil` for the HTTP adapter. A routed transport receives the same signed
  request and retains attempts, result classification, history, and telemetry.
  It owns destination semantics and skips the packaged send-time destination
  gate. Invalid results and callback faults retry as `transport_resolution`;
  they never silently fall back to HTTP.
- `AshHooks.DestinationPolicy` returns `:allow`, `:deny`, or `:default` for a
  URL and endpoint/tenant context. Allow replaces the driver's packaged gate,
  deny is terminal, and default uses the packaged resolver. Callback faults
  retry as `destination_policy_failed`. Adapter-side resolution and pinning
  remain a separate boundary. Unsafe answers are terminal; DNS failures retry.
- `retryable_statuses` replaces the ordinary HTTP retry set. Success,
  redirect refusal, and 410 disablement stay fixed; invalid sets fail before
  claiming. An empty set disables ordinary HTTP retries. Retryable HTTP
  responses honor the bounded Retry-After policy.
- Host delivery headers resolve per send and must be valid binary pairs.
  Signing, content-type, and framing names are reserved case-insensitively.
  Callback or validation failure retries before sending.
- Exact-certificate, certificate-hash, and public-key-info-hash TLS pins
  supplement normal TLS validation. They require HTTPS and the bounded
  adapter; mismatch, pin-resolution failure, and invalid configuration are
  terminal. A per-endpoint resolver overrides adapter options, including
  an explicit `nil` that turns pinning off.

Worker timing defaults can be resolved per perform through `runtime_config`.
The compiled job timeout must exceed the attempt budget plus finalization
allowance, and its attempt ceiling must exceed the row ceiling. Budgets must
be positive integers with ordered backoff bounds; literal adapter timeouts
must fit inside the attempt budget. Runtime overrides recheck that same
compiled envelope and reject unknown keys before delivery work, emitting
classified configuration telemetry and leaving the row unchanged. A literal
adapter destination-validation bypass is refused outside the test environment;
computed adapter options remain trusted host configuration.

The worker macro accepts named resolver callbacks where runtime functions
cannot be safely embedded. Direct delivery retains documented function forms.
Configuration is not cached in process-local state. ADR-0015 owns transaction
and spawned-work behavior; ADR-0013 owns secret resolution and custody.

[Subscription](../../lib/ash_hooks/subscription.ex) selection matches exact
event names or the bare wildcard, with atom and string names normalized for
comparison. Optional attribute filters use a closed declared key set and event
metadata: clauses combine with AND, list values match any member, and unknown
keys, missing metadata, or malformed filter containers do not match. Selection
occurs before creating delivery rows. Subscription pause is recorded in ADR-0020.

[Catalog](../../lib/ash_hooks/catalog.ex) exposes declared descriptions,
schemas, examples, versions, and version builders. An endpoint without a pin,
or pinned to the current version, receives the event's exact bytes. Other pins
require a declared builder returning nonempty bytes. Unknown versions, failed
builders, invalid results, and crashes fail that endpoint before row creation;
fanout to other endpoints continues. The package never substitutes the current
payload for a failed pinned version.

## Consequences

Hosts own the security properties of configured overrides and custom transports,
including destination validation where they replace it. Receiver input cannot
select those overrides. The runtime preserves one delivery state machine while
refusing policy errors at their defined boundaries. Catalog and filter changes
require host coordination with endpoint expectations and subscription data.

## Amendment: November 17, 2026

Endpoint signers may append ordered headers after native signing and host delivery headers. Reserved names and existing names are refused. Adapters and transports that implement send_prepared/2 own the exact request target, header order and body contract. Host-signed deliveries refuse an adapter without that capability before invoking the signer. See [ADR 0028](0028-host-extension-seams.md).
