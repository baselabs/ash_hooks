# 0028: Host extension seams

Status: Accepted November 17, 2026.

## Context

Hosts authenticate webhooks with schemes this package does not implement natively. HTTP Message
Signatures (RFC 9421) is one example. Before this record, such a host ran into four limits:

- **Inbound facts.** A verifier could return only `:ok`, so what it verified was lost to audit
  and to the handler.
- **Inbound upstream results.** A result verified upstream could not reach the provider. The
  provider verified again, and a one-time nonce was claimed twice.
- **Outbound context.** A host signature could be added only inside an HTTP adapter, which gets
  no delivery, endpoint, tenant or attempt. The native Standard Webhooks secret was mandatory even
  for an endpoint whose receiver accepts only the host's scheme.
- **Outbound wire guarantee.** Nothing guaranteed that the request line and headers a signature
  covers reach the receiver unchanged.

The package stays scheme-agnostic: it depends on no signature package, and companion packages
adapt to these seams.

## Decision

### Verified facts

- `inbound_delivery do record_verified_facts :on end` injects a nullable, sensitive
  `verified_facts` map.
- `verify_signature/3` may return `{:ok, facts}`. The facts have string keys and JSON values, a
  depth of at most 8 and at most 8 KiB encoded. Any other shape fails closed as `:unknown_error`.
- The winning verification's facts persist with the first authenticated receipt on every branch:
  current key, previous key, source refresh and scheme providers.
- `DeliveryContext.verified_facts` exposes them to the handler, and recovery rebuilds them from
  the row.
- The retention sweep deletes facts with their row. Redaction clears them.
- With the option off, `{:ok, facts}` is admitted and the facts are dropped.
- Facts are what the provider chose to keep, never credentials, signatures or raw signature
  parameters.

### Upstream context

- The Plug resolver and `Ingress.ingest` accept an opaque `host_context`, which reaches the
  provider in its verification context.
- Only the provider admits a request. A provider that reuses an upstream result must bind it to
  the request body, tenant and source policy.
- `host_context` is never persisted, inspected or included in an error.

### Signer

- The endpoint resource declares `signer`, `signer_attributes` and `native_signing`
  (`:required` by default, or `:optional`). A Spark verifier checks the declaration.
- `AshHooks.Signer.sign/2` receives:
  - the prepared request;
  - the delivery, endpoint, attempt and event id;
  - the explicit tenant, plus the canonical custody tenant when the resource declares a
    custodian.
- It returns new headers with the key refs used, `:skip`, `{:error, :retry}` or
  `{:error, :terminal}`.
- The signer runs after native signing and `delivery_headers`, outside database phases and inside
  the attempt deadline.
- These are retryable `signer_failed`: a malformed or empty result, a collision with an existing
  header, a reserved header name, and a raise, throw or exit. Only `{:error, :terminal}`
  dead-letters, before any transport.
- A configured signer that does not skip must succeed. A delivery that nothing signs is refused.
- With `native_signing :optional`, `secret_ref` may be nil. Custody endpoints move between
  native, both and host-only signing through package actions that keep the key registry and
  disposal intact. Native signing then adds only `webhook-id` and `webhook-timestamp` when it has
  no reference.
- Every entry path (dispatch, test send, resend and replay) signs at send time from the
  endpoint.
- Replay rows take the signing mode of the endpoint's matching subscription, reading all
  pages of the consumer's primary read action under the explicit tenant. The
  [amended replay rules](0020-resend-replay-and-endpoint-health.md) govern subscription
  eligibility. Conflicting matching modes return an error.

### Prepared request

- `%AshHooks.Http.Request{}` carries the method, the exact request target, the complete ordered
  header lines (including `host`, `content-length`, `content-type` and `connection`) and the
  body. These are fixed before the signer runs.
- Adapters and transports may implement the optional `send_prepared/2` callback, which sends
  exactly that request line, those lines in that order, and the body. `request/5` is unchanged.
- `AshHooks.Http.Bounded` implements `send_prepared/2`.
- `AshHooks.Http.Httpc` does not advertise `send_prepared/2`. Raw-listener qualification on
  supported OTP found that `headers_as_is` still rewrites the request target's `x=%2f` to
  `x=%2F`. It therefore cannot promise the exact signed bytes. Bounded remains the built-in
  adapter for host signers. The contract test asserts the absent capability rather than
  depending on this third-party behavior remaining unchanged.
- When the endpoint resource declares a signer, an adapter without `send_prepared/2` is refused,
  terminally, before the signer runs, and never downgraded.

### Signing provenance

- `outbound_attempt do record_signing_provenance :on end` injects `signing_key_refs`: every
  native reference used plus the signer's key refs.
- The 410 recovery snapshot carries this list.
- `signing_key_ref` names the current reference of the mode actually used, or the signer's first
  ref when only the signer signed.
- A signer failure before sending records no latency and no key ref.
- `[:ash_hooks, :delivery, :sign]` reports the signing duration and outcome class.

This record amends:

- **ADR 0012:** the 410 snapshot and conditional disable include `signer_attributes`, compared as
  typed values, and treat a nil `secret_ref` as a value. A snapshot without a signer key never
  disables the endpoint.
- **ADR 0019:** signing provenance is a list. Signer failures are a pre-send stage.
- **ADR 0021:** a signer may add any header except a reserved delivery header or one already
  present. An adapter that implements `send_prepared/2` takes on its exact-wire obligation as a
  trusted boundary.

## Consequences

### Additive in a minor release (ADR 0010)

- Each new column is opt-in, and the host migrates it before enabling the option. A host-only
  endpoint needs a migration that relaxes `secret_ref`'s NOT NULL.
- With every option off, schemas, adapters and the bytes on the wire are unchanged.
- The singular key ref and the replay signing mode change as corrections of existing defects.

### Hosts and receivers

- Hosts that sign with their own scheme do it per endpoint, with the explicit tenant, through
  their own key custody.
- Receivers can verify a host signature over exactly the bytes they received.

### Custom adapters

- A custom adapter that cannot send prepared requests cannot carry host-signed deliveries.
