# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 0.1.0 — 2026-08-22

### Added

- Inbound machine: `AshHooks` + `AshHooks.InboundDelivery` extensions,
  `AshHooks.Ingress` (verify-before-trust, fenced unique-ingest dedup
  ledger, lease-based claim, crash-window re-drive), provider behaviour
  with ComplyCube/HubSpot v3 references and a test provider.
- Outbound machine: `AshHooks.dispatch/4` fanout with per-endpoint
  isolation and enqueue-repair CAS; `AshHooks.OutboundDelivery`,
  `AshHooks.Subscription`, `AshHooks.Endpoint` extensions.
- Delivery runtime (`AshHooks.Delivery`) + host-injected
  `use AshHooks.Worker`: Standard-Webhooks signing (standard/dual/legacy
  envelopes), row-owned retry policy (Retry-After, jittered backoff,
  dead-letter ceiling), 410 durable disable, redirect refusal, send-time
  SSRF re-check.
- `AshHooks.Http` adapter behaviour with a memory-bounded native
  HTTP/1.1 default (`AshHooks.Http.Bounded` — every read capped under
  all framings) and an OTP `:httpc` alternative.
- Response-snippet DLP (ADR-0005 amendment): no body bytes by default
  (fixed-grammar status + allowlisted content-type summary); per-call
  `snippet_capture` opt-in under the in-package redaction floor (NFKC
  homoglyph folding, bounded-fixpoint decode chain, separator-tolerant
  markers, ≥16-char union-alphabet entropy rule); fail-closed consumer
  `snippet_redactor` callback; `[captured]` marking.
- Telemetry (ADR-0005 floor: ids/integers/fixed atoms/classified
  reasons only — never secrets or bodies): ingress verify/dedup/claim,
  dispatch enqueue_failed, delivery attempt/result/backoff/dead_letter/
  disable; `AshHooks.Telemetry.fingerprint/1`.
- Igniter installer, DSL cheat sheets, get-started tutorial,
  usage-rules.md.

### Security

- Package floors shipped in-code (ADR-0005): secrets as sources only
  (literals rejected at parse), default-deny machine-written ledger
  fields, SSRF guard at registration and send, header allowlist, no
  response-body persistence by default, classified-only error strings.
