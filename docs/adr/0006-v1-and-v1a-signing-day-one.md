# 0006 - SW v1 and v1a (ed25519) signing, both schemes

## Context

Standard Webhooks supports HMAC-SHA256 (`v1`) and Ed25519 (`v1a`).
Asymmetric signing lets receivers verify with a public key without a shared secret.

## Decision

The signer and verifier implement **both `v1` and `v1a` natively**: `v1,<base64
HMAC-SHA256>` and `v1a,<base64 ed25519>` in the space-delimited `webhook-signature` header,
per-endpoint key material (`whsec_` symmetric 24 to 64 bytes; `whsk_`/`whpk_` asymmetric),
old and new rotation signing for both. `Signing.headers/4` accepts `:previous_whsk`
for overlapping Ed25519 keys. Secrets are resolved via callbacks (ADR-0005).

## Consequences

- Receivers can verify with public keys alone (no shared-secret distribution) where the
  consumer chooses ed25519 endpoints.
- Two code paths in signing/verification tests; both covered by the SW-vector and
  tamper-negative gates.
