# Security policy

ash_hooks is an auth-boundary library — signature verification, secret handling, and
SSRF guarding are its core. Security reports are welcome and taken seriously.

## Reporting a vulnerability

**Do not open a public issue for a security vulnerability.**

Use GitHub's private vulnerability reporting: the **Security** tab of this repository →
*Report a vulnerability* (enabled 2026-08-22). It reaches the maintainer privately and
coordinates disclosure.

Include what you can: the affected surface (inbound verification, outbound signing,
SSRF guard, HTTP adapter, retention/redaction), a minimal reproduction, and the versions
involved. **Never include real secrets or production signed payloads** — synthesize the
smallest bytes that reproduce.

You will get an acknowledgement within 7 days. Fixes for accepted vulnerabilities ship
as patch releases on the supported minor (ADR-0010) and are credited in the CHANGELOG
unless you prefer otherwise.

## Scope

In scope:

- Signature verification bypasses (any path where an unauthenticated or replayed
  delivery is accepted)
- Secret exposure (DSL/config leakage, storage of secret-derived bytes, telemetry)
- SSRF guard escapes (destination validation, DNS-rebinding, redirect chains, TLS
  verification weaknesses)
- Memory/resource exhaustion through the HTTP adapters
- Redaction/retention escapes (payload bytes surviving where they must not)

Out of scope:

- Consumers' own policies, domains, or deployments (the package injects no read
  policies — ADR-0005's consumer-governed posture; operators own their authz)
- Vulnerabilities in dependencies themselves (report upstream; we track and bump)
- Anything behind an explicitly relaxed floor (a consumer opting into unbounded
  adapters, disabled destination validation in tests, etc.)

## Known posture notes

These are deliberate design postures, not vulnerabilities — each documented with its
rationale:

- The `:httpc` adapter assembles giant NON-2xx bodies inside OTP before the package
  cut (its moduledoc); `AshHooks.Http.Bounded` (the default) bounds every framing.
- Literal-IP https endpoints require the IP in the certificate's iPAddress SAN
  (ADR-0009) — a cert without it fails closed with `:cert_ip_mismatch`.
- Raw provider payloads persist in the ledger by design (verification and audit
  require them); read exposure is governed by consumer policies (ADR-0005 amendment).
