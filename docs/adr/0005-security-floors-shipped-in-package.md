# ADR-0005 — Security floors ship in the package, not as consumer homework

- **Status:** Accepted (2026-08-20) — snippet policy amended 2026-08-22
  (design-validated, 2026-08-22):
  response snippets store NO body bytes by default (status + allowlisted
  content-type token only, no digest); body capture is an explicit
  per-call opt-in under the package floor (NFKC + decode chain +
  ≥16-char union-alphabet entropy run + separator-tolerant markers) with
  a fail-closed consumer `snippet_redactor` callback ahead of the floor.
  Read-posture amended 2026-08-22 (adversarially reviewed): read
  authorization is CONSUMER-GOVERNED, not package-injected — the
  original "default-deny reads" floor is restated below as the
  documented posture + recipe, with the injected-authorizer alternative
  rejected on its true costs.
- **Deciders:** maintainer; independent adversarial review (blocking finding)

## Context

Webhook payloads and ledgers carry untrusted input and secrets adjacent to authorization
boundaries. Delegating policies/classification entirely to "consumer-side concerns" strips
the safety floors the reference platform runs (scoped reads, field policies, encrypted
secrets) from the reusable package — an authorization and data-exposure regression for
adopters with no migration layer, and a banned restriction-shaped narrowing.

## Decision

The package ships RESTRICTIVE DEFAULTS as floors, which consumers relax explicitly.
**As-built floors** (two original lines corrected by the 2026-08-22 amendment, marked):

- Read authorization on ledger/delivery resources *(amended)*: the package injects NO
  read policies — reads are governed ENTIRELY by the consumer's own domain policies. The
  original decision text claimed a package-enforced "default-deny reads" floor; as built
  and as maintained, that floor is DOCUMENTED, not injected: README → Security, the
  tutorial's policy step, usage-rules.md, and READ-EXPOSURE warnings on the resource
  moduledocs carry the posture plus a copy-paste deny-by-default policy recipe.
  Rationale — the enforcement/DOCUMENTATION split: every other floor below protects a
  surface the PACKAGE owns (attacker-facing mechanics: memory, literals, DNS, sockets)
  and can be owned mechanically; read authorization requires the CONSUMER's model (who
  are your actors? what may they read?) — definitionally the host app's decision. A
  package-shipped policy guesses at that model.
  Rejected alternative: injecting `Ash.Policy.Authorizer` plus a read-scoped
  `forbid_unless` policy. The package's own runtime is unaffected (every internal call
  runs `authorize?: false`), but attaching ANY authorizer activates policy evaluation on
  every consumer-initiated call on the resource: consumers who never wrote policies must
  (their own scripts, admin reads, and code_interface calls would be denied), existing
  consumer policies interact in order-sensitive ways, and 0.x adopters' read semantics
  would flip in the 1.0.0 commit — the one change that would make 1.0.0 breaking. An
  OPT-IN strict-reads mode (e.g. `inbound_delivery strict_reads: true`) remains available
  additively post-1.0 if demand appears.
- Stored inbound headers *(amended — as-built is stricter)*: NOTHING is stored — no
  header attribute exists on either ledger; verification reads headers ephemerally and
  persists only payload + digest.
- Outbound response snippets store no body bytes by default (status + allowlisted
  content-type token only); body capture is an explicit per-call opt-in under the
  in-package floor (NFKC + decode chain + ≥16-char union-alphabet entropy run +
  separator-tolerant markers) with a fail-closed consumer `snippet_redactor` callback
  ahead of the floor.
- Secrets resolvable only via callbacks; rows carry secret REFERENCES
  (`AshHooks.Endpoint.SecretRef` strings) — never secret material, never digests
  *(amended: the original "stored as digest + redacted display" mechanism did not ship;
  references are stricter for the threat that matters — no secret-derived bytes at rest)*.
  Literal secrets in DSL/config rejected at compile time.
- Telemetry carries 8-hex secret fingerprints only; retention (TTL) and field-redaction
  hooks provided; SSRF guard enforced at endpoint registration AND send time (scheme,
  private/link-local/metadata ranges, send-time DNS re-resolution — ADR-0009);
  per-endpoint circuit breaking is a durable `:disabled` transition on the Endpoint
  resource (plus the 410 rule), not an in-process fuse. Inbound pipeline is
  verify-before-trust, fail-closed on missing secrets / missing raw body (loud
  misconfiguration error, never silent accept).

## Consequences

- Adopters restore parity through declared slots + hooks rather than reimplementing floors.
- Raw payloads persist by default (verification and audit require them) — bounded by
  retention hooks, redaction on read surfaces, and the consumer's read policies.
- The read posture is the one DOCUMENTED-only floor; the amendment records why the
  asymmetry is deliberate and what the rejected injection would have cost.
- Slightly more concept surface than a bare engine; each floor maps to a named silent
  failure mode.
