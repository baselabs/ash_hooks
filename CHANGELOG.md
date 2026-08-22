# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

## 1.0.0 — 2026-08-22

1.0.0 is the semantic-versioning baseline (ADR-0010): no public API
removals or renames from 0.2.x. Three behavior corrections below;
migration notes in [UPGRADING.md](UPGRADING.md).

### Fixed

- **Truncated chunked responses no longer classify as success.** The
  default HTTP adapter returned a partial body as `{:ok, ...}` when a
  chunked response was cut by early close — a 2xx on partial bytes
  could mark a delivery `:succeeded`. Chunked now returns
  `{:error, :truncated_body}` exactly like the Content-Length framing,
  and the driver retries.
- **The literal-IP https certificate check actually works now.** The
  iPAddress-SAN matcher was unreachable since birth (found by the new
  dialyzer gate): every literal-IP https endpoint was rejected
  fail-closed with `:cert_ip_mismatch`. Extracted to the
  fixture-tested `AshHooks.Http.CertSan` (ADR-0009). The IPv6 direction
  initially matched nothing (a cross-vendor review finding, fixed
  before release) — both address families now verify against fixture
  certificates.
- **A hostile chunked response can no longer balloon worker memory.**
  The chunk consumer accumulated the ENTIRE attacker-declared chunk
  before trimming to the body bound — an 8MB declaration held ~16.8MB
  in the worker against a 16-byte bound (cross-vendor security review,
  executable probe). Consumption is now phase-bounded: keep at most the
  allowance, discard the excess slice-wise (one receive slice held at a
  time), and a chunk terminator that is not CRLF is now
  `{:error, :malformed_chunked}` instead of being silently consumed
  (a malformed 2xx can no longer classify as succeeded). Run-on
  chunk-size lines without a terminator are refused past a sane bound
  instead of being buffered.
- `AshHooks.Delivery.prune/2` returns `{:error, error}` when the
  resource lacks `inserted_at` — the same contract as
  `AshHooks.Ingress.prune/2` its `@spec` always promised (previously
  raised `ArgumentError`).

### Added

- **Semver and support policy** (ADR-0010): the covered public surface
  is named, deprecations run two minors, and the minimum supported
  versions are CI-tested (Elixir ~> 1.17 / OTP 27+ / Ash ~> 3.0 /
  Oban ~> 2.20 optional). The previously claimed Elixir 1.15 floor was
  never buildable with current Ash and is corrected here — 1.0.0 is
  the first release whose floor is actually tested.
- **SECURITY.md** with a private disclosure channel (GitHub private
  vulnerability reporting, enabled), scope, and known posture notes;
  **CONTRIBUTING.md** and **UPGRADING.md** — all three ship in the
  tarball and render on hexdocs.
- **Dialyzer gate** on the public API (local + CI) — first run caught
  the dead IP-SAN matcher above.
- **CI**: a floor leg resolving dependencies at the declared minimums
  (it disproved the old 1.15 claim on its first run), a package leg checking the hex tarball ships
  every documentation file and that the DSL cheat sheets match the
  DSL, and an advisory coverage report.
- `@spec` on the HTTP behaviour's `request/5` (both adapters),
  `AshHooks.dispatch/4`, the resource extensions'
  `statuses/0`/`signing_modes/0` (now documented), and the
  `AshHooks.Http.Target` helpers.
- A dedicated extension-shape test suite for `AshHooks.OutboundDelivery`,
  pinning the injected attributes, the `unique_delivery` identity, and
  the `:dispatch` no-touch-upsert contract.

### Changed

- **Read posture documented honestly** (ADR-0005 amendment): read
  access to the ledger/delivery resources is consumer-governed — the
  package injects no read policies. README → Security carries the
  deny-by-default policy recipe; the resource moduledocs now carry
  READ-EXPOSURE warnings. (No code change: reads were always
  consumer-governed; the docs previously implied otherwise.)
- Install guidance is `{:ash_hooks, "~> 1.0"}`; the README (previously
  pinned `~> 0.1.0`, one feature-release behind) and tutorial both
  corrected, with the install-constraint check added to the release
  checklist.

## 0.2.2 — 2026-08-22

### Fixed

- usage-rules.md now ships in the hex tarball (the Ash AI-assistant
  convention reads it from the package) and renders on hexdocs. It was
  previously GitHub-only.

## 0.2.1 — 2026-08-22

### Added

- A runnable get-started Livebook (guided tour: inbound verify/dedup,
  a live local delivery, telemetry, retention) — CI-verified headless
  on every push. No functional changes.

## 0.2.0 — 2026-08-22

### Added

- Retention hooks (ADR-0005 floor completed): `AshHooks.Ingress.prune/2`
  and `AshHooks.Delivery.prune/2` (terminal rows older than a cutoff,
  keyed on the resource's `timestamps()`; non-terminal rows never
  deleted), and `AshHooks.Ingress.redact_payload/4` (payload
  field-redaction under the claim fence; the original-bytes digest is
  preserved). Deleting a terminal row re-opens its dedup identity —
  set TTLs beyond replay/re-emission horizons.

## 0.1.1 — 2026-08-22

### Changed

- README rewritten as a package front door (no functional changes):
  audience/register pass; internal build references removed.

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
- Response-snippet redaction floor (ADR-0005 amendment): no body bytes
  by default (fixed-grammar status + allowlisted content-type summary);
  per-call `snippet_capture` opt-in under the in-package redaction
  floor (NFKC homoglyph folding, bounded-fixpoint decode chain,
  separator-tolerant markers, ≥16-char union-alphabet entropy rule);
  fail-closed consumer `snippet_redactor` callback; `[captured]`
  marking.
- Telemetry (ADR-0005 floor: ids/integers/fixed atoms/classified
  reasons only — never secrets or bodies): ingress verify/dedup/claim,
  dispatch enqueue_failed, delivery attempt/result/backoff/dead_letter/
  disable; `AshHooks.Telemetry.fingerprint/1`.
- Igniter installer, DSL cheat sheets, get-started tutorial,
  usage-rules.md.

### Security

- Package floors shipped in-code (ADR-0005): secrets as sources only
  (literals rejected at parse), default-deny machine-written ledger
  fields, SSRF guard at registration and send, NO headers stored on
  either ledger at all, no response-body persistence by default,
  classified-only error strings.
