# ADR-0006 — SW v1 and v1a (ed25519) signing, day one

- **Status:** Accepted (2026-08-20) — v1a rotation landed 2026-08-21 (`Signing.headers/4` `:previous_whsk`, #6 slice): "old+new rotation signing for both" is now true as written, no phase
- **Deciders:** operator directive ("compatible if not canon") re-derived under adversarial Category-10 audit

## Context

The Standard Webhooks spec defines two signature schemes: `v1` (HMAC-SHA256, symmetric) and
`v1a` (ed25519, asymmetric). Deferring `v1a` on "no adopter needs it today" is consumer-
demand framing — banned; and Erlang/OTP's `:crypto` implements ed25519 natively (no
dependency cost), while asymmetric verification (publish a public key, keep the private
one) removes secret-distribution from public receivers.

## Decision

The signer and verifier implement **both `v1` and `v1a` from day one**: `v1,<base64
HMAC-SHA256>` and `v1a,<base64 ed25519>` in the space-delimited `webhook-signature` header,
per-endpoint key material (`whsec_` symmetric 24–64 bytes; `whsk_`/`whpk_` asymmetric),
old+new rotation signing for both. Secrets are resolved via callbacks (ADR-0005).

## Consequences

- Receivers can verify with public keys alone (no shared-secret distribution) where the
  consumer chooses ed25519 endpoints.
- Two code paths in signing/verification tests; both covered by the SW-vector and
  tamper-negative gates.
