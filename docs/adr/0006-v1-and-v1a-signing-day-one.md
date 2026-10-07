# ADR-0006 — SW v1 and v1a (ed25519) signing, day one

- **Status:** Accepted August 20, 2026; rotation support clarified August 21, 2026.
  `Signing.headers/4` accepts `:previous_whsk` for overlapping Ed25519 keys.
- **Deciders:** Maintainer; independent design review.

## Context

The Standard Webhooks spec defines two signature schemes: `v1` (HMAC-SHA256, symmetric) and
`v1a` (ed25519, asymmetric). The runtime provides the necessary cryptographic
operations. Asymmetric verification lets receivers use a public key while
the sender retains its private key, avoiding shared-secret distribution.

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
