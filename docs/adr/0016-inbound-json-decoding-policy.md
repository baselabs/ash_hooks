# 0016 — Inbound JSON decoding policy

- **Status:** Accepted November 15, 2026
- **Deciders:** maintainer

## Context

A host may require one JSON policy for ambiguous or unacceptable documents.
Applying it only to delivered payloads leaves protected headers and claims on a
different policy. A provider-owned decoder can also bypass the ledger's policy
unless the callback receives that policy explicitly.

## Decision

The inbound ledger's `json_decoder` is an MFA, defaulting to
`{Jason, :decode, []}`. [Ingress](../../lib/ash_hooks/ingress.ex) constructs a
one-argument decoder for each request and shares it with signature verification
and payload decoding. The decoder must return an acceptable map or list, or an
error; malformed results and callback faults are contained.

[Signature.jws/3](../../lib/ash_hooks/provider/signature.ex) uses this decoder
for the protected header before authentication and for claim inspection after
authentication. Header rejection fails verification. Claims are checked only
when the authenticated payload decodes to an object; a claim-decode rejection
does not itself reject the returned authenticated bytes. The subsequent
policy-aware payload decode applies the decoder again and refuses a rejected
payload for handling. Host-defined callbacks must honor the supplied policy.
The exact verification boundary is recorded in ADR-0005.

Payload decoding has explicit precedence in
[AshHooks.Provider](../../lib/ash_hooks/provider.ex):

1. A declaration's `body_format` overrides provider decoders and format hints.
2. A generated JWS decoder uses its scheme and the request's supplied decoder.
3. A host `decode_payload/2` receives the supplied decoder and takes precedence
   over a host `decode_payload/1`.
4. Without those callbacks, the provider's `body_format/0` applies, then JSON
   is the default. Form decoding preserves its own flat-field and UTF-8 rules.

Ledgers that explicitly configure `json_decoder` refuse host-defined
`decode_payload/1` without `/2` on every provider that can reach them: a
declaration's `provider`, and every module in the provider allowlist of a
declaration's `source_record`, since a row's alias selects among them. Generated
`/1` callbacks are exempt because ingress uses their scheme with the supplied
decoder directly; direct calls to generated `/1` retain the default decoder.
`Scheme.decode_payload/3` also accepts the decoder.

[AshHooks.Provider.Conformance](../../lib/ash_hooks/provider/conformance.ex)
supplies a consumer test proving that a hand-written `/2` returns data from the
supplied decoder for the exercised input. It does not prove every envelope path;
hosts must exercise their supported shapes. Only consumer tests require the
test framework.

## Alternatives

No alternative was recorded at the time in the available release notes.
Independent header and payload decoders would leave a policy gap. An implicit
process-local decoder would make callback behavior depend on hidden state.
Keeping an unrestricted host `/1` alongside configured policy could silently
bypass that policy. Passing the decoder explicitly and rejecting that callback
shape makes the obligation visible, while generated callbacks can satisfy it
without changing their direct-call contract.

## Consequences

Custom providers must decode all JSON through the supplied function when using
`/2`, including JSON extracted from envelopes. Explicit format choice remains
the host's responsibility. Verification authenticates bytes; successful
authentication alone does not make a rejected JSON document processable.
