# 0017 — Generic providers and signature primitives

- **Status:** Accepted November 15, 2026
- **Deciders:** maintainer

## Context

Different senders reuse signature mechanisms while varying headers, encodings,
signed inputs, timestamps, and envelopes. Version 3.0.0 removed the shipped
vendor-specific verifier modules and provider-name inference. The public
mechanism must describe the actual signing contract and leave sender-specific
configuration and business handling with the host.

## Decision

Every inbound declaration names its provider explicitly. A missing provider
fails at compilation rather than resolving a module from the declaration name.
Names continue to define durable ledger identity; replacing an implementation
does not justify changing that name or silently changing existing identities.

`use AshHooks.Provider, verify: [...]` generates callbacks from validated
[Scheme](../../lib/ash_hooks/provider/scheme.ex) configuration. Supported
primitives include HMAC, RSA with fixed padding and digest, ECDSA with fixed
curve and signature format, Ed25519, and compact JWS. Configuration specifies
signature source and encoding, key decoding, exact signed input, timestamps,
and tolerance. Structured headers admit a bounded number of candidate signatures.
Generated callbacks can be overridden for a host protocol.

The default `AshHooks.Provider.Event` uses the fixed `:webhook` type and keeps
sender event names in the payload, without converting them into atoms. Hosts
override event parsing and handling to apply their own domain classification.

[AshHooks.Provider.Signature](../../lib/ash_hooks/provider/signature.ex)
exposes the primitives for hand-written verification. JWS requires a host-pinned
algorithm matching its protected header, unpadded base64url segments, and the
standard encoded signing input. Unsecured algorithms, unsupported critical
headers, and unencoded payloads fail closed; key-location headers do not supply
trusted keys. Time claims are checked after authentication. Request-based
signature callbacks can inspect ordered request header lines without requiring
a separate signature context value.

Configured JWS providers decode the authenticated payload and derive their
default identity from its full canonical JSON. Explicit declaration identity
extractors retain precedence; provider identity errors fail closed. ADR-0012
records the replacement of the historical vendor normalization. ADR-0016 owns
the shared JSON policy and decoder precedence.

## Alternatives

- Keeping vendor modules was the pre-3.0.0 model. Each sender variation then
  belonged to the package's public implementation and release contract. Generic
  schemes express reusable verification mechanisms while hosts own sender policy.
- Inferring a provider from its name hides implementation selection and makes
  renaming configuration affect durable identity. Explicit selection separates
  the two responsibilities.
- Trusting an algorithm or key location supplied by the token would let
  unauthenticated input choose verification policy. Host-pinned configuration
  keeps that policy outside the request.
- Requiring every provider to reimplement cryptography duplicates validation and
  encoding rules. Public primitives support protocols that need custom input
  construction without duplicating those mechanisms.

## Consequences

Moving from removed modules is a major-version migration. Hosts supply provider
modules, protocol configuration, and tests for their sender's actual contract.
Preserving an old identity normalization requires an explicit host callback and
audited adoption where needed. The package maintains generic configuration,
signature primitives, and their classified failure contracts.
