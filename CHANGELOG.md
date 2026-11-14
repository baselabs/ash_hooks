# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## 3.1.0 (November 13, 2026)

Inbound webhooks get an HTTP entry point: `AshHooks.Plug` takes a request from
the router to the ledger and answers it, with no controller code. The minimum
supported Ash version increases to 3.37.2 to exclude versions affected by three
published advisories. No schema change and no breaking API
change; see [UPGRADING.md](UPGRADING.md).

### Added

- `AshHooks.Plug`, an optional generic Plug adapter for inbound HTTP delivery,
  with endpoint resolution, tenant and scope context, exact raw-body reads,
  configured public request URIs, and a public default response mapping. `refuse:`
  lets hosts shape refusal headers and bodies while preserving status and required
  headers; `retry_after:` sets default 503 retry hints (60 seconds by default).
  `signature_header:` (or a resolver's `:signature_header`) names the header whose
  single value becomes `ctx.signature` for a provider on the default `:header`
  signature source; a missing or repeated header is refused as unsigned.
- Optional `c:AshHooks.Provider.handshake/1` and `c:AshHooks.Provider.response/1`
  callbacks for sender challenges and acknowledgment protocols. The plug also
  accepts a host response policy.
- `AshHooks.BodyReader.put_raw_body/2` and `raw_body/1` provide a public exact-byte
  contract for host endpoint readers and lower-level ingress callers, without a
  second body read or access to an implementation-specific connection key.

### Changed

- **Ash floor raised to 3.37.2** (`{:ash, ">= 3.37.2 and < 4.0.0-0"}`), so that
  no admitted Ash release carries a published advisory: EEF-CVE-2026-96581
  (HIGH, fixed in 3.37.2), EEF-CVE-2026-114214 (MEDIUM, 3.37.1) and
  EEF-CVE-2026-101028 (MEDIUM, 3.34.6) all affect releases the 3.0.0 floor
  (3.34.3) admitted. A floor rise is a minor change (ADR 0010); see
  [UPGRADING.md](UPGRADING.md).

### Security

- CI gains a `security` job that fails closed. OSV's scanner (pinned 2.7.1,
  checksum-verified) runs offline, with no network, against OSV's Hex database
  downloaded first, over the development lock and over the lock a consumer
  resolves at the declared Ash floor; each lock must be exactly what Mix writes,
  and the scanner must read every `:hex` and `:git` entry Mix counts
  (`scripts/check-advisories.sh`, with a fixture lock holding both kinds). `mix hex.audit` fails on a retired package.

### Fixed

- A verified body that did not decode to a map or list could be rebuilt from its empty placeholder, handled, and marked processed. It is now recorded permanently malformed when written and never handled. Duplicate deliveries still drive the surviving row's stored payload.
- Event-log terminal replay forwards its tenant to resend.
- Missing-row event-log replay binds the declaration and enqueue route, stores the requester, and enqueues the created delivery and event.
- Health sweeps count and emit disable telemetry only for successful writes.
- Endpoint health returns `{:error, :from_required}` for `:to` without `:from`.
- Health sweeps enforce the full warning interval from the stored warning time, including early and overlapping sweeps. The interval is the new `auto_disable` option `warning_interval_seconds` (default 60).
- Delivery pruning checks history deletion and rolls back the batch on failure, keeping history with its delivery.
- HTTP 410 history retains the request's actual duration and signing-key reference through disable recovery.
- Synchronous ingestion contains handler exceptions, exits, and throws and records retryable failures.
- Entry points validate tenancy across every resource they read or write, including optional history and event logs.
- Worker compilation requires a positive integer `delivery_max_attempts`.
- Previous-key retirement records the actual retirement time, including early removal.
- Health sweeps count and emit warning telemetry only for committed warning markers.
- Test sends validate optional history tenancy before creating a delivery.
- Worker compilation rejects fractional job timeout and maximum-backoff budgets.
- Event-log replay dry runs count the selected batch without creating deliveries.
- Event-log replay enforces its configured batch rate.

### Documentation

- Previous signing keys remain active until their stored references are removed.
- Inbound pruning excludes tracked `:failed_verification` rows.
- Replay dry runs count a limited batch; skipped rows can appear in repeated calls.
- Test sends use `:signing_mode`, defaulting to `:standard`, without reading subscriptions.
- Paginated queries require an `:id` attribute; a full last page still has a cursor.
- Signature recipes use application-defined headers and signing contracts.
- Guide examples are compiled and executed from their marked blocks against real databases.

### Dependencies

- Updated the development toolchain and locked dependencies to: Elixir 1.20.5
  on Erlang/OTP 29.1.2 (OTP 28 stays in the supported window and the CI
  matrix), Ash 3.37.4, Spark 2.7.10, AshSqlite 0.3.1 (test substrate),
  Dialyxir 1.4.9, Makeup 1.2.3. The PostgreSQL leg runs PostgreSQL 18.

## 3.0.0 (November 11, 2026)

Inbound verification becomes generic: describe any sender's signature scheme in
configuration, or write one callback with public primitives. The package no
longer ships vendor-specific verifiers. Two breaking changes are listed below with
their replacements; [UPGRADING.md](UPGRADING.md) gives the configuration for
each removed module. No schema or dependency changes.

### Breaking

- **Removed the vendor verifier modules** `AshHooks.Provider.ComplyCube` (and
  `ComplyCube.Event`), `AshHooks.Provider.HubSpotV3` (and `HubSpotV3.Event` and
  `decode_request_uri/1`), `AshHooks.Provider.Twilio`, `AshHooks.Provider.Stripe`,
  `AshHooks.Provider.Shopify`, `AshHooks.Provider.WooCommerce`,
  `AshHooks.Provider.Shippo`, `AshHooks.Provider.EasyPost`,
  `AshHooks.Provider.Magento2`, `AshHooks.Provider.BigCommerce`,
  `AshHooks.Provider.Ecwid`, `AshHooks.Provider.Squarespace`, and
  `AshHooks.Provider.Wix`. Replacement: a provider module in your application,
  usually `use AshHooks.Provider, verify: [...]` with the options UPGRADING lists
  for each one.
- **Removed the name-to-module convention.** An inbound declaration without
  `provider` no longer resolves `AshHooks.Provider.<CamelizedName>`; it fails to
  compile with a message naming the fix. Replacement: set `provider` on every
  inbound declaration, keeping the inbound name unchanged so existing
  deduplication identities still match.

### Added

- `use AshHooks.Provider, verify: [...]` generates a provider from configuration:
  HMAC with SHA-1, SHA-256, SHA-384 or SHA-512; RSA PKCS#1 v1.5 and RSA-PSS with
  SHA-256, SHA-384 or SHA-512; ECDSA P-256 and P-384 with DER or raw `r || s`
  signatures; Ed25519; and compact JWS bodies with the algorithm pinned by the
  host. Signatures come from a named header (optionally prefixed), a structured
  header of key/value pairs carrying up to 16 signatures, or the body. Hex,
  base64 and base64url encodings; raw, hex or base64 secrets with an optional
  prefix; PEM public keys, X.509 certificates or raw Ed25519 keys; a signed input
  built from the body, timestamp, method, URL, path, headers and literals, or by a
  host function; timestamps in seconds or milliseconds from a header, a signature
  field or a host function, with a symmetric tolerance. Options are checked at
  compile time and every generated callback can be overridden.
- `AshHooks.Provider.Scheme` documents those options. `new!/1` validates them,
  `verify/4` verifies with them directly, and `payload_identity/1`,
  `decode_payload/2`, `timestamp_header/1` and `signature_source/1` back the
  generated callbacks.
- A provider configured with `signature: :jws_body` also gets `decode_payload/1`,
  which stores the verified JWS payload, and `event_identity/1`, which
  deduplicates on the SHA-256 of that payload as canonical JSON
  (`AshHooks.Provider.Scheme.payload_identity/1`) instead of the raw-body digest.
  Two encodings of the same signed content share one ledger row.
- `AshHooks.Provider.Signature.jws/3` and `:jws_body` accept only unpadded
  base64url segments, as RFC 7515 requires. A token that contains `=` fails with
  `:invalid_signature`.
- `AshHooks.Provider.Signature` is public: `hmac/4`, `rsa/4`, `ecdsa/4`,
  `ed25519/4`, `jws/3`, `compare/2`, `header/2` and `check_timestamp/3`, for
  providers that implement `verify_signature/3` themselves.
- The optional `signature_source/0` callback accepts `:request`, for providers
  that read their own signature from the request headers; ingress then needs no
  `ctx.signature`.
- `AshHooks.Ingress.ingest/4` accepts the request headers as an ordered list of
  `{name, value}` pairs, such as `conn.req_headers`, as well as a map. Providers
  receive every line in arrival order in the new `ctx.header_list`, and repeated
  lines are joined with `", "` in `ctx.headers`. A map the host passes is
  delivered unchanged, as before.
- `AshHooks.Provider.Hmac` accepts `:sha384` and `:sha512` algorithms.
- A "Verify any sender" guide with recipes for common signature shapes.

### Changed

- `AshHooks.Ingress.ingest/4` fails verification when `headers` is neither a map
  nor a list of binary `{name, value}` pairs. A list reaches providers as a map in
  `ctx.headers` and in full in `ctx.header_list`.

## 2.3.0 (November 11, 2026)

### Added

- Inbound routes can accept `application/x-www-form-urlencoded` bodies: declare
  `body_format :form` on the route, or return it from a provider's optional
  `body_format/0`. Signatures are verified over the exact raw bytes before
  decoding; JSON stays the default. Providers can decode a signed body envelope
  after verification. Invalid UTF-8 fields are recorded as a permanent malformed
  payload.
- Native signature verifiers for Twilio (form and JSON), Stripe, Shopify,
  WooCommerce, Shippo, Adobe Commerce/Magento 2, BigCommerce Standard Webhooks,
  Ecwid, Squarespace, and Wix RS256 body JWTs. Each module cites its vendor
  contract. The new verifier modules classify every event as `:webhook` and
  never convert input to atoms.
- EasyPost's API/SDK `X-Hmac-Signature` verifier: exact `hmac-sha256-hex=` prefix,
  lowercase-hex raw-body HMAC-SHA256, NFKD-normalized UTF-8 webhook secrets,
  constant-time comparison, and overlap rotation through `previous_secret`.
- Additive EasyPost v2 verification per its HMAC help article: UTF-8
  timestamp/method/path/body HMAC-SHA256 with no separators, RFC 2822 numeric
  timezone parsing, 60-second maximum age and 30-second future allowance,
  case-insensitive constant-time signature comparison, and overlapping secrets.
  The signed path must equal the host's existing `request_uri` context. A present
  v2 header never falls back to v1. Existing v1 verification stays unchanged.
- A host-configured HMAC verifier for emitter-defined contracts: header name,
  SHA-256/SHA-1, hex/base64, optional signed timestamp and tolerance, canonical
  input, and overlap keys, for application-defined signing contracts.
- Optional outbound retry-status selection, preserving current defaults and the
  existing success, redirect, and 410 rules.
- Optional outbound host headers resolved per delivery, with case-insensitive
  protection for signing, content-type, and framing headers.
- Optional exact certificate, certificate SHA-256, or SPKI SHA-256 pins on the
  bounded HTTP adapter, selected per endpoint or host configuration. Normal TLS
  checks remain required. Pin failure closes before sending and does not retry.

### Fixed

- Tenant-aware one-argument inbound `paused` and `previous_secret` sources
  receive the resolved tenant and take effect on multitenant ledgers. Tenant-less,
  zero-argument, `{module, function, args}` and app-env sources behave as before.
- Previous-secret app-env sources resolve the documented binary keys while
  preserving the legacy `{:ok, key}` value shape.

No new dependencies or schema changes.

## 2.2.1 (November 8, 2026)

### Fixed

- **A sustained-failure disable now always follows an earlier WARNING
  sweep.** In 2.2.0, the first `AshHooks.EndpointHealth.sweep/3` that saw
  an endpoint already meeting the disable thresholds
  (`failure_share` + `min_attempts`) disabled it immediately; the
  `[:ash_hooks, :endpoint, :disable_warning]` the moduledoc promised
  never fired, and the notify surface got no chance to reach anyone
  before the breaker opened. The warned state is now durable: declaring
  `auto_disable` injects the `disable_warned_at` marker column (migrate
  it with the declaration), the first qualifying sweep warns and stamps,
  and the disable lands on the next sweep that still qualifies, clearing
  the stamp. Recovery below the warning band clears the stamp, so a
  later degradation gets a fresh warning cycle. (Found while adopting the
  package in a downstream application.)

## 2.2.0 (November 8, 2026)

A minor under the public support policy: everything new is additive opt-in surface; no
existing column, action, default, or event changes shape. Adopt what you
need; each block names its DSL declaration and migration. Read
[UPGRADING.md](UPGRADING.md) before adopting.

### Added

- **Attempt history.** The new `AshHooks.OutboundAttempt` extension turns a
  consumer resource into the per-attempt audit ledger: one durable row per
  delivery attempt (time, outcome, classified reason, HTTP status, latency
  in milliseconds, and the signing key REFERENCE, never secret material),
  written by the runtime beside its fenced result transitions and idempotent
  per `(delivery, attempt)`. Latency is the REQUEST's duration, recorded
  whenever a request was attempted (including one that failed at
  transport, at destination pinning, or in a crashing adapter) and `nil`
  only when no request was ever made (destination-policy refusal, DNS
  failure at the send gate, secret resolution), where the signing key is
  `nil` too. Wire it with `attempts:` on the worker macro or
  the direct-run config. A history write failure never fails the send; it
  surfaces as `[:ash_hooks, :attempt, :record_failed]` telemetry.
- **Per-endpoint response capture.** `response_capture_attributes :on` on
  the endpoint resource injects per-row capture columns; an endpoint that
  sets `response_capture: true` records bounded (`response_capture_max_bytes`),
  redacted response bodies and only `response_header_allowlist`-named
  response headers in its attempt rows. Capture stays off by default
  everywhere.
- **Delivery-log queries.** `AshHooks.Delivery.list/2` and
  `AshHooks.OutboundAttempt.list/2`: filter by endpoint, status/outcome,
  event type, and time range with keyset pagination (newest-first,
  `(time, id)` cursors), tenant pre-flighted like every package entry
  point.
- **Test events.** `AshHooks.Delivery.test_send/2` sends one signed
  synthetic test event of a chosen type to ONE endpoint, OUTSIDE
  subscriptions; no subscription row is consulted, and the delivery lands
  in the ledger like any other. Each send carries a fresh `msg_` id (never
  dedup-suppressed), the chosen type verbatim, and a self-marking default
  payload (`{"test": true, "type": ..., "timestamp": ...}`; a
  caller-supplied payload is used verbatim). Emits
  `[:ash_hooks, :delivery, :test]` beside the normal lifecycle, drives the
  row synchronously (default one attempt), requires a live endpoint, and
  returns `{:ok, %{status:, delivery:}}`.
- **The finishing details.** Test sends are now FLAGGED end to end:
  `test_tracking :on` on the delivery ledger injects the `test` column,
  `AshHooks.Delivery.test_send/2` rows carry `test: true`, attempt
  history rows flag themselves, and both list queries filter on `test:`;
  test sends appear in the delivery log, clearly marked. The
  per-delivery diagnostic capture (`snippet_capture: true`) rides every
  driver call including test sends, beside the per-endpoint setting.
  Catalog entries carry an `example` payload. Health stats report
  FIRST-ATTEMPT successes separately from EVENTUAL successes (and the
  delivery count). Attempt history prunes WITH its delivery rows
  (`prune/2`'s `:attempts` option). And a test send can target the
  transport; a CLI "listen" command's trigger arrives as a signed,
  test-marked payload on the developer's forwarder.
- **Inbound parity.** `AshHooks.Ingress.list/2` queries inbound
  deliveries by source, status, event type, and time range with keyset
  pagination; `counts/2` answers the window's story (received,
  duplicates ignored, failed verifications, handler failures) with
  `ingress_tracking :on` on the ledger (the `duplicates` counter column
  and payload-less `:failed_verification` rejection rows, digest
  identity). The inbound DSL's `previous_secret` source rotates a source
  with an overlap window (both keys verify until the option is removed),
  and `paused` (any secret-source shape resolving a boolean) refuses
  every request with `{:error, :source_paused}`; answer 5xx so the
  provider retries; nothing is lost while paused.
- **Tenancy across the new surface.** Every new entry point (attempt
  history reads and writes, delivery-log queries, resend and replay, test
  sends, health stats and the disable sweep, key rolling and expiry, the
  event log's list/prune/replay) takes `:tenant`, resolves the tenancy
  pre-flight first, and fails closed with `{:error, :tenant_required}` on
  multitenant resources without one. Multitenant attempt tables carry the
  tenant-partitioned `unique_attempt` index (the delivery ledger's
  pattern); `AshHooks.Endpoint.expire_previous_secret/2` gained its
  `:tenant` option.
- **The event log.** The new `AshHooks.OutboundEvent` extension records
  each dispatched event ONCE (id, type, declared payload version, time,
  and exact payload bytes), whether or not any endpoint was enabled (wire it
  with `events:` on the outbound declaration). The log is idempotent on the event
  id; a failed log write never stops the fanout
  (`[:ash_hooks, :event, :record_failed]`). Its own retention
  (`AshHooks.OutboundEvent.prune/2`), keyset queries by type and time
  range (`list/2`), and replay: `AshHooks.OutboundEvent.replay/3` sends
  one event or a filtered set to a CHOSEN endpoint (including one that
  was off at the time or added later), keeping the event id (receivers
  dedup), re-arming terminal rows through resend, and recording who
  asked everywhere.
- **The delivery transport behavior.** `AshHooks.Transport` is the
  behavior for routing ONE endpoint's deliveries to your own transport
  (a developer's local forwarder behind a CLI "listen" command, for example) instead of
  HTTP: an adapter-shaped `request/5` receiving the SAME signed request
  the wire would, with the runtime's attempts, attempt history,
  classification, backoff, and telemetry applying unchanged. Route per
  endpoint with `transport: {module, function}` / a 2-arity fn (worker
  option or direct-run config) returning the transport module or `nil` to
  keep the HTTP adapter; a routed endpoint skips the packaged send-time
  destination gate (the transport owns destination semantics), and a
  crashing resolver or non-module return falls back to HTTP contained.
- **Subscription filters on declared event attributes.** The
  subscription DSL's `filter_attributes([:order_id, :region])` declares
  the closed set of attribute names subscriptions may filter on and
  injects the `event_filters` column (`:map`): a subscription whose
  filters all equal the dispatching event's metadata values receives the
  delivery; multiple filters AND together, a list value matches any-of.
  Filters are evaluated in the dispatcher BEFORE any delivery row is created; a
  filter key outside the declared set (or a malformed filter value) never
  matches, fail closed. Attribute values ride the event's `metadata`.
- **The event catalog and payload-version pinning.** The `outbound` DSL
  declares each event type's metadata: `description`, `payload_schema`
  (any term your docs renderer understands), `version` (default 1), and
  optional `payload_versions` (a map of `version => {module, function}`
  variant builders). Read it back through `AshHooks.Catalog.entries/1` and
  `entry/2` for event pickers and doc generation. Declaring
  `version_pinning :on` on the endpoint resource injects
  `pinned_payload_version`: an endpoint pinning a DECLARED version
  receives that variant builder's exact bytes instead of the dispatch
  payload (per-endpoint rows carry their own bytes); a pin on an
  undeclared version, or a failing/crashing builder, fails that endpoint
  closed before any row is written; the fanout continues.
- **Endpoint health and sustained-failure auto-disable.**
  `AshHooks.EndpointHealth.stats/2` computes one endpoint's trailing-window
  health from its attempt history: success rate and nearest-rank latency
  percentiles (p50/p90/p99 ms). The new `auto_disable` section on the
  endpoint resource declares the policy beside the existing 410 rule
  (`failure_window_seconds`, `failure_share`, `min_attempts`, and warning
  thresholds); `AshHooks.EndpointHealth.sweep/3` disables an endpoint whose
  window meets the share with the minimum evidence (through the same
  durable switch the 410 rule uses) and emits
  `[:ash_hooks, :endpoint, :disable_warning]` BEFORE it disables; the
  notify surface gets its chance at the warning thresholds.
  Re-enabling stays an explicit application action.
- **Secret rolling with an overlap window.** `key_lifecycle :on` on the
  endpoint resource injects the six signing-key lifecycle columns
  (created / first-used / retired for the current key and its predecessor,
  all timestamps and never secret material) and unlocks
  `AshHooks.Endpoint.roll_secret/2`: the incumbent reference moves to
  `previous_secret_ref` (the Standard Webhooks zero-downtime seam, where both
  keys sign every delivery until the window ends with multiple signatures on the
  wire), the new reference takes its place, and the old key's retirement
  is scheduled (`:overlap_seconds`, default 24h).
  `expire_previous_secrets/2` is the scheduled sweep;
  `expire_previous_secret/1` retires at once on request. The delivery
  runtime stamps each key's first use at signing time (nil-gated, only on
  lifecycle resources).
- **Resend and bulk replay.** `AshHooks.Delivery.resend/2` re-arms one
  terminal delivery row (`:succeeded`/`:dead_letter`) with the SAME event
  id (a Standard Webhooks receiver deduplicates the repeat POST), while
  the lifetime attempt counter keeps climbing (attempt-history rows stay
  unique) and a fresh retry ladder starts at `resend_baseline`.
  `AshHooks.Delivery.replay/2` re-arms a filtered set (endpoint, event
  type, status list, time range) with `dry_run: true` counting matches
  and `:per_second`/`:limit` bounding the rate. Both record who asked
  (`last_resend_by`/`last_resend_at`, `resend_count`), refuse anything
  but live endpoints (`{:error, :endpoint_not_live}` / counted skips),
  and require the new `resend_tracking :on` DSL (four migrated columns);
  existing schemas are untouched. Every re-arm emits
  `[:ash_hooks, :delivery, :resend]`.

- **A public send-time destination policy seam.** `AshHooks.DestinationPolicy`
  is the supported way to carry your own allow and deny rules without forking
  the packaged SSRF check: a `{module, function}` callback (worker option
  `:destination_policy`, or the same key in a direct
  `AshHooks.Delivery.run/2` config) receives the endpoint's URL and a
  `%{endpoint_id:, tenant:}` context and decides `:allow` (skip the packaged
  gate; pair it with the HTTP adapter's validation override for destinations
  that check would refuse), `:deny` (terminal `destination_denied`), or
  `:default` (the packaged tri-state check runs unchanged). A callback that
  crashes or returns a term outside the vocabulary is contained as a
  retryable `destination_policy_failed`; a policy defect never dead-letters
  deliveries. A configured policy takes precedence over the boolean
  `:ssrf_check` seam; with no policy configured, behavior is unchanged.

- **Runtime-configurable worker timing.** `use AshHooks.Worker` accepts
  `runtime_config: {module, function}`; the callback receives the Oban
  job's args (tenant included) on every perform and returns a keyword of
  overrides for `:delivery_max_attempts`, `:base_backoff_seconds`,
  `:max_backoff_seconds`, `:retry_after_cap_seconds`, `:attempt_timeout`,
  and `:finalization_allowance`, merged over the compiled defaults. Every
  compiled-budget misfit check re-runs at runtime against the resolved
  set (positive integers, backoff ordering, the baked Oban job-timeout
  envelope including a literal `http_opts` `timeout:` collision, and the
  Oban-ceiling relation, since only the row ceiling may decide dead-letter): a
  violation fails the job with `{:error, {:invalid_runtime_config, reason}}`
  before any delivery work, leaves the row untouched, and emits
  `[:ash_hooks, :worker, :invalid_runtime_config]` (the reason vocabulary is
  fixed; a contained callback crash is `callback_failed`). The public
  resolver `AshHooks.Worker.resolve_config/2` backs the seam.

## 2.1.0 (November 1, 2026)

A minor under the public support policy, not a patch: `AshHooks.Ssrf.resolve_public/1`
is covered surface and its documented DNS-failure vocabulary changed
(`:unresolvable` → `:nxdomain` | `:resolve_timeout`), and `use
AshHooks.Worker` now refuses previously-compiling misfit configurations at
compile time. No schema, DSL, or success-path change; read
[UPGRADING.md](UPGRADING.md) before adopting.

### Fixed

- **Unresolvable DNS is transport, not a verdict on the destination.** The
  default send-time destination check now runs the tri-state
  `AshHooks.Ssrf.resolve_public/1` instead of the boolean `safe_url?/1`,
  which folded *unresolvable* into *unsafe*: a resolver outage (or mere
  congestion past the two-second resolution ceiling) permanently
  dead-lettered healthy endpoints at `attempts == 1` under the
  `unsafe_destination` label, while the same condition surfacing one layer
  later (inside the HTTP adapter) retried as transport. Now a validated-unsafe
  answer still dead-letters immediately as `unsafe_destination`; an
  unresolvable host retries under its honest label: `nxdomain` when every
  queried address family answered authoritatively negative, `resolve_timeout`
  for an outage, congestion, or mixed evidence (both in the telemetry reason
  vocabulary; `nxdomain` had sat unused there), and a permanently dead
  domain dead-letters at the row ceiling carrying that label. The HTTP
  adapter's umbrella atom for the same failures is `unresolved_host` (also
  newly in the vocabulary, as it previously collapsed to `unclassified`).
  Consumer-observable: rows that would have been terminal at attempts == 1
  now climb the backoff ladder; consumers branching on an immediate
  `unsafe_destination` for DNS-dark endpoints see
  `failed_retryable`/`nxdomain`/`resolve_timeout` rows instead. The
  injected `:ssrf_check` boolean seam is unchanged (false still dead-letters
  as `unsafe_destination`).
- **Compiled worker-budget tripwires.** `use AshHooks.Worker` now refuses,
  at compile time, related budgets whose silent misfit stalls rows or walls
  off every slow send: Oban's `:max_attempts` must exceed
  `:delivery_max_attempts` (error-class results, such as attempt timeout, driver
  crash, and endpoint read errors, consume Oban executions in step with row
  attempts while snooze-class results consume none, so only the row ceiling
  may decide dead-letter; a larger row ceiling against the default Oban
  ceiling truncated the retry ladder mid-flight and stalled rows until a
  recovery trigger), a literal `:http_opts` `timeout:` must stay below
  `:attempt_timeout` (the runtime kills the attempt at the budget wall
  before the driver's own deadline), the macro validates positive attempt, finalization, base-backoff,
  and Retry-After budgets, and `:max_backoff_seconds` must be at least
  `:base_backoff_seconds`. A literal `:http_opts`
  `validate_destination: false` (the test seam for loopback listeners)
  now refuses to compile outside `:test` (with it baked in, the driver's
  send-time check would be the only remaining SSRF layer; an `{m, f, a}`
  bundle resolves per-perform and cannot be compile-checked).
  Previously-compiling misfits now raise `ArgumentError` at compile.

### Docs

- The `:http_opts` option of `AshHooks.Worker` now states its trust posture:
  `validate_destination: false` (the test seam loopback listeners use)
  disables the adapter's resolve-and-pin defense, is refused at compile
  outside `:test`, and must never ship to production. The
  `AshHooks.Delivery` classification table gains the unresolvable-DNS row.
- The send-time SSRF classification is now pinned end-to-end with real DNS
  through the package's own driver: a registration-clean hostname whose
  send-time answer is private is refused by `AshHooks.Http.Bounded`'s
  resolve-and-pin and dead-letters through the runtime (no injected
  refusal, no `validate_destination` bypass). Checks also cover the driver-side
  unresolvable arm and the default-check arms for both classes.

### Dependencies

- Lock-only substrate refresh clearing every published advisory and all
  resolver-updatable drift (the shipped requirement lines are unchanged;
  the declared Ash floor stays `>= 3.34.3` and the floor qualification
  still pins it): ash 3.34.6 → 3.37.2 (EEF-CVE-2026-96581 HIGH,
  EEF-CVE-2026-114214 MEDIUM), ash_postgres 2.14.5 → 2.15.2
  (EEF-CVE-2026-115627, EEF-CVE-2026-115635, plus the retired-package
  notice), plug_crypto 2.2.0 → 2.2.1 (EEF-CVE-2026-105963), and the
  currency drift igniter 0.8.5, oban 2.24.2, spark 2.7.9, splode 0.3.3
  (with their transitive closure). `mix hex.audit` and
  `scripts/check-currency.sh` are clean against the new lock.

## 2.0.4 (October 9, 2026)

### Fixed

- Generated Oban workers no longer report Dialyzer pattern-match warnings for
  unsaved uniqueness conflicts. Oban's job type declares a persisted ID but its
  Basic engine can return an unsaved conflict; admission reads the ID through a
  private map helper. Retry limits, not-persisted refusals, identity checks, and
  runnable-state checks retain their behavior.
- The type gate now compiles the same generated worker used by the PostgreSQL
  suite. Real Oban.Basic transaction tests force an unsaved conflict, verify
  retry after the winning transaction commits, and verify refusal after all
  twenty retries.
- Dependency currency: Ash 3.34.4 → 3.34.6 (resolves EEF-CVE-2026-101028 in the
  locked graph) and AshPostgres 2.14.3 → 2.14.5.

## 2.0.3 (October 7, 2026)

### Fixed

- Delivery diagnostics survive recovery races, end to end. Re-admission no longer
  wipes `last_error`: a successful release after a durable enqueue replays the row's
  admission-time diagnostic (the story of the failure that scheduled the retry:
  `http_503` stays visible through the retry; only a fresh enqueue failure writes a
  new error). Every outcome that resolves the row's immediate fate (`mark_succeeded`,
  `mark_send_failed` (both the terminal and the retryable form), `finalize_disable`,
  and the stored 410 obligation itself (`mark_disable_pending`)) now RELEASES the
  enqueue claim in the same statement, so a reconciler whose enqueue raced the
  outcome finds the token gone. A release that then matches zero rows on a
  cleared claim classifies as BENIGN COMPLETION (`:reconciled`, never
  `:endpoint_error`); only a still-live foreign claim is a genuine
  `:stale_enqueue_claim`. And a successful release now PARKS the enqueue lease for
  one horizon (30s): a concurrent recovery sweep can no longer re-admit the row in
  the instant between the token clearing and the sweep ending; admission is
  exactly-once per recovery window at the seam itself (the concurrent-reconciler
  contract the suite pins, previously upheld only by SQLite's statement
  serialization; the final coverage gate caught the true-concurrency gap). The
  `:release_enqueue` machine primitive gains an optional `enqueue_lease_expires_at`
  argument (default nil, with no change for direct callers). Consumer-observable
  consequence: a recovery sweep that runs inside a freshly admitted row's
  30-second parked-lease horizon now reports that row as a contended
  `:duplicate` where 2.0.2 re-admitted it; sub-30s recovery cadences and
  `:duplicate`-count alerting will see the new shape. A row whose release
  reload finds it deleted or unreadable now reports `:enqueue_reload_failed`
  instead of a stale-claim error. Regression tests reproduce the recovery races on SQLite and PostgreSQL.
- Test: the 5xx backoff bound is asserted exactly (4..7); the legacy `<= 8` accepted an
  unreachable value.

## 2.0.2 (October 7, 2026)

### Fixed

- Outbound `Retry-After` is honored on every retryable status, not only 408/429: a 5xx
  response carrying the header (the canonical 503 overload signal) now schedules the
  receiver's own recovery window; an absent or malformed header keeps the backoff
  fallback. Note the bound this moves: a
  header-bearing 5xx snooze is clamped by `retry_after_cap_seconds` (default 86,400s),
  not `max_backoff_seconds` (default 3,600s); if you shortened `max_backoff_seconds` to finish retries sooner, also lower
  `retry_after_cap_seconds`.
- Test dependency currency: `ash_postgres` 2.14.2 → 2.14.3.

## 2.0.1 (October 6, 2026)

Version 2.0.1 includes the delivery ownership, recovery, and
migration changes below. The guided tour keeps protocol implementations available
for resources defined during notebook evaluation.

### Fixed

- Disable protocol consolidation in the Livebook setup so dynamically defined Ash
  resources use their custom display without consolidation warnings.
- Update the notebook, release tooling, and production consumer to 2.0.1.

## 2.0.0 (October 6, 2026)

The changes below first shipped in 2.0.1.

Delivery rows now retain declaration and queue ownership, fence each send attempt,
and recover unfinished work after queue exhaustion or an interrupted endpoint disable.
HubSpot retries use a stable batch identity, and the default transport bounds the
complete HTTP operation.
**Existing installations require the ordered schema and identity migration in
[UPGRADING.md](UPGRADING.md) before running 2.0 workers or ingress.**

### Changed

- Outbound rows persist declaration ownership and queue route. A declaration
  cannot recover another declaration's rows. Named callbacks have stable routes;
  anonymous callbacks can supply `enqueue_key` for durable recovery.
- Send and recovery admission use separate UUID tokens and expiring leases.
  Every result is fenced to the live attempt; retry ceilings are checked before
  sending. The complete ledger primary key is used throughout.
- A 410 response records `:disable_pending` before disabling the matching endpoint
  configuration. Recovery completes that obligation without another HTTP request.
- Oban uniqueness covers runnable jobs and the durable route/tenant identity.
  Completed or discarded jobs do not strand recoverable rows; an unpersisted
  conflict is an admission error.
- HubSpot's default dedup identity canonicalizes the complete batch, ignoring only
  each outer event's `attemptNumber`. The optional provider `event_identity/1`
  callback follows an explicit declaration extractor in precedence. Retained
  legacy rows are adopted explicitly, preserving payloads and an audit map.
- Ash's supported floor is 3.34.3, including its security correction and the tenant
  inverse API used by workers. The lock resolves Ash 3.34.4, AshPostgres 2.14.2,
  and Spark 2.7.6.

### Fixed

- Minimal production consumers start `:public_key` and `:ssl` through the package's
  application dependencies; optional packages are unnecessary for default HTTPS.
- Direct delivery calls apply the documented retry defaults for omitted or `nil`
  settings, including the attempt ceiling and bounded `Retry-After`, without
  requiring an Oban worker.
- Required keyset pagination, bounded retention deletion, custom ledger keys,
  renamed UUID endpoint/subscription keys, and aliased worker HTTP-option resolvers.
- Endpoint status values are cast and constrained at compile time; empty enabled
  sets, overlapping states, and primary-key mappings are rejected.
- IDs on direct event structs and HTTP headers reject control bytes and malformed UTF-8.
  Telemetry reasons use a fixed vocabulary, preventing arbitrary tokens from escaping.
- SSRF classification covers special-purpose address ranges; IPv6 Host values are
  bracketed. Bounded HTTP follows interim responses to the final response, stops
  at its body cap, and uses one deadline across resolution and transport.
- HubSpot's finite event taxonomy includes generic object events.

### Documentation and delivery

- Current install/version pins, terminal inbound acknowledgments, generated DSL
  references, migration instructions, and an executable 2.0.0 Livebook.
- Package archive inspection and notebook execution precede publication; the
  normal notebook then executes against the exact published version.
- Documentation changes trigger Linux CI. The minimum-consumer leg pins Ash
  3.34.3; package, PostgreSQL, coverage, and Livebook checks feed `all-checks-pass`.

## 1.3.0 (October 5, 2026)

Additive options for domain naming and lifecycle, a compile
fix for generated (non-writable) primary keys, typed subscription
matching, loud documentation of the policy/id/adapter obligations, and a
Linux CI leg exercising an AshPostgres `uuid_v7` consumer shape.

### Added

- **`payload_attribute` on the `outbound_delivery` section.** The exact
  payload-bytes column's name is configurable (default `:payload`):
  rename it when the consumer's domain reserves `payload` for its own
  sole payload store. The injected column, the `:dispatch` accept list,
  and every signing/sending read follow the configured name; a name
  colliding with another injected field fails closed at compile.
- **`prune_action :none` on the `outbound_delivery` section.** Opt out
  of the retention `destroy :prune` action's injection for append-only
  audit ledgers (no destroy action exists on the resource at all);
  `AshHooks.Delivery.prune/2` then fails loud with a named error;
  deletion is the consumer's own surface. Default `:destroy` is
  unchanged.
- **`status_attribute` / `enabled_values` / `disabled_value` on the new
  `endpoint` section.** Map the durable enable/disable onto the
  consumer's OWN switch (e.g. an `active` boolean): `status` is then
  not injected. There is one switch, so the consumer's off switch and the
  package's can never silently disagree. The dispatcher's skip and the
  send path's dead-letter both route through `AshHooks.Endpoint.enabled?/1`;
  the 410 auto-disable flips the mapped attribute. The mapped attribute
  must be consumer-declared (fail-closed at compile).
- **A Linux CI leg with a Postgres service** exercising the transformers
  against an AshPostgres, uuid_v7-keyed, sole-store-payload consumer
  shape (`postgres` job; the suite is env-gated by `ASH_HOOKS_POSTGRES=1`
  and excluded from ordinary dev runs). `ash_postgres` is a dev/test-only
  dependency; it never ships or constrains consumers.

### Fixed

- **`:dispatch`/`:ingest` no longer accept `:id` on resources whose
  primary key is a non-writable `:id`** (e.g. `uuid_v7_primary_key`):
  Ash's `ValidateAccept` raised at compile on exactly that consumer
  shape, making the extensions unadoptable without replacing the PK.
  The accept lists carry `:id` only when the PK is a writable `:id`
  (the package-injected default, with byte-identical classification); the
  transformer's decision is persisted and the runtimes read it back, so
  the compiled action and the classification path can never disagree
  (composite and non-`:id` primary keys included). For the non-writable
  shape, created/duplicate classification pre-reads the unique identity
  instead: exact in every sequential case (provider redeliveries,
  producer re-fires) and wherever the primary read can see the existing
  row (a base-filtered read that hides it classifies `:created`). Under
  a misclassification the storage upsert preserves one row.
  ~~A double send stays impossible through the `mark_sending` CAS and
  inbound claim fence.~~ **Correction in 2.0.0:** the 1.3 outbound
  state transition did not fence every late result or expired owner.
  Version 2.0 adds attempt tokens, leases, and separate enqueue claims;
  network sends remain at-least-once and require receiver deduplication.
  In 1.3 the enqueue seam was the configured
  enqueuer's own fence: the default Oban enqueuer's
  endpoint_id+event_uuid job uniqueness, or the consumer's own dedup
  for a custom `enqueue:`. Public support policy note: the injected action accept
  lists are covered surface; this is a behavior correction (the
  previous accept list required a writable PK that consumers with
  generated PKs cannot provide), not a removal; no working consumer can
  regress (the shape did not compile).
- **With the endpoint status mapping, the send path
  dead-letters an endpoint whose status is anything other than
  `:enabled`** (previously only an exact `:disabled` dead-lettered, so a
  consumer-redeclared `status` with extra values delivered). The
  dispatcher's skip and the send path now route through the ONE
  `AshHooks.Endpoint.enabled?/1` check, which fails closed by design.
- **`AshHooks.Subscription.matches?/2` normalizes `event_types` entries
  with `to_string/1`.** An atom-typed register (`{:array, :atom}`, a
  closed enum) previously matched NOTHING: zero deliveries, no error.
  Atom and string entries (and the `"*"`/`:"*"` wildcard in either
  representation) now match identically. Consumers redeclaring
  `event_types` keep their own constraints; the injected `["*"]`
  default is not forced on them.

### Changed

- **CI is Linux-only; the macOS and Windows build legs are removed.**
  Tri-OS stays a developer-portability requirement (clone, set up, and
  test must work on every OS); it was never meant to be a CI topology,
  and the README no longer claims dedicated per-OS legs. Also hygiene:
  the workflow's pinned GitHub Actions (checkout, cache, upload-artifact)
  moved off the Node 20 runtime to their current releases. No library
  code changed.
- **The DSL cheat-sheet drift gate is no longer vacuous.** The package
  leg's `mix spark.cheat_sheets --check` ran without an extension list
  and checked nothing; it now passes the five extensions explicitly, so
  a stale `documentation/dsls/` actually fails the build (the sheets in
  this release are regenerated under that invocation).
- **Dev/test `mint` bumped 1.10.1 → 1.11.0** (EEF-CVE-2026-94194 /
  -91043 / -92103, via the dev-only igniter→req→finch tree; never ships
  in the package). `ash_postgres` 2.13.1 is added dev/test-only for the
  Postgres leg above.

### Docs

- **Policy obligation at the extension site** (`OutboundDelivery`,
  `Endpoint` moduledocs): the injected write actions are named and the
  consumer-owned policy obligation is stated loudly, mirroring the inbound half's
  "you write your own" posture outbound. The seven delivery
  actions plus the endpoint's `:disable`.
- **Deterministic `Event.id` guidance** (`Event`, `Dispatcher`
  moduledocs): derive the id from the artifact's stable id; a generated
  id turns every producer re-fire into a duplicate POST per sweep.
- **The adapter-author contract** (`AshHooks.Http` moduledoc): headers
  must be a LIST of `{name, value}` tuples (a map silently loses
  `Retry-After`), and the resolve-once/connect-pinned obligation that
  closes the DNS-rebinding TOCTOU is the adapter's, with the driver's
  send-time check as the residual.
- **`retry_after_cap_seconds` semantics** (`Worker` moduledoc): the
  default Retry-After cap allows a receiver to delay each attempt by up to
  24 hours. Lower the cap if your application requires a shorter retry period.
- **The 410 auto-disable posture** (`Delivery` moduledoc): an
  unattributed system bulk write by design (no actor in a versioned
  register), with no built-in tenant-facing signal. A receiver that answers
  410 once goes dark silently unless the app wires the
  `[:ash_hooks, :delivery, :disable]` telemetry event or accepts the
  posture in writing.

## 1.2.1 (September 24, 2026)

### Fixed

- **The documentation tree now ships in the hex tarball.** 1.2.0's package
  carried only the top-level docs (README, CHANGELOG, UPGRADING, usage-rules),
  so `documentation/` (including the multi-tenant adoption checklist) was
  reachable only on GitHub/hexdocs while UPGRADING.md and the CHANGELOG
  referenced it by repo-relative path. Installed-package readers now get the
  tutorials (get-started, tenancy-adoption-checklist), the DSL reference, and
  the Livebook alongside those references. No library code changed; hexdocs
  and the package page README are unaffected.

## 1.2.0 (September 24, 2026)

Tenancy release: ash_hooks aligns with
Ash attribute multitenancy. An explicit tenant threads every data call,
and the package fails closed with named errors before any data access
when a multitenant resource is touched without one. Single-tenant
adopters change nothing: the entire pre-1.2 suite passes unchanged over
tenant-less fixtures inside the now-610-test gate, because threading a
tenant through resources with no multitenancy declaration is
mechanically inert.

### Added

- **Tenant threading on every path**: `AshHooks.dispatch/4` (`:tenant`
  opt), `AshHooks.Ingress.ingest/4` (`ctx[:tenant]`), the claim/mark/
  renew/redact/prune/reap heads (`:tenant` opt, new optional arity),
  `AshHooks.Delivery.run/2` (tenant recovered from job args), and both
  prunes. The tenancy contract: consumers declare
  `multitenancy :attribute, attribute: <same attr>` on the resources a
  given operation touches; the package verifies that set on every entry
  point and returns `{:error, :tenant_required}` /
  `{:error, :tenancy_mismatch}` before any data access (Ash's native
  fail-closed stays the backstop; `global?: true` is rejected; it
  silently disables fail-closed reads). A compile-time verifier
  additionally rejects `multitenancy :bypass`, `:bypass_all`, and
  `:allow_global` actions on multitenant package resources.
- **Per-tenant operations**: `AshHooks.reap_all/2` and
  `AshHooks.prune_all/2` sweep a tenant enumerable sequentially with
  per-tenant error isolation and totals
  (`{:ok, %{results: %{tenant => {:ok, n} | {:error, reason}}, total: n}}`).
- **`AshHooks.reconcile_pending/3`**: the supported reconciliation for
  delivery rows stranded at `:pending` by a crash between row write and
  enqueue: a WHERE-gated CAS flip to `:enqueue_failed` (a real state
  change, where matched-records is the win signal and exactly one reconciler wins per
  row, proven under a custom non-Oban seam), then enqueue through the same seam dispatch takes. Exactly-once
  ACROSS claim mechanisms (reconciliation vs re-dispatch repair) is the
  enqueue seam's contract: the canonical Oban seam's job uniqueness
  provides it; a custom seam must be idempotent itself.
- **Tenant-aware secret resolution (all optional)**: the worker macro's
  `:tenant_aware_secrets` (2-arity `f(ref, tenant)` resolver contract);
  the inbound `secret fn tenant -> ... end` source; the provider
  behavior's optional `webhook_signing_secret/2`
  (Organization × connection custody; `use AshHooks.Provider` ships an
  overridable default delegating to `/1`); and `:tenant` in the
  `verify_signature/3` context map.
- **Oban args carry the tenant**: the generated `enqueue/2` serializes
  the row's tenant (string tenants are the supported shape; non-string
  tenants must round-trip `parse_attribute` over JSON); uniqueness keys
  stay `[:endpoint_id, :event_uuid]`, and a pre-tenancy tenant-less job
  still conflicts with the tenant-bearing job on the same pair (proven
  on the real Oban engine).
- The dispatch result contract is now a public typespec
  (`t:AshHooks.Dispatcher.dispatch_result/0`) including the new
  `:reconciled` status.
- The multi-tenant adoption checklist
  (documentation/tutorials/tenancy-adoption-checklist.md) and the public support policy.

### Migration notes

Two adopter classes see action; single-tenant staying single-tenant
sees none. See UPGRADING.md and the adoption checklist: (1) cutover
with in-flight Oban jobs created before 1.2.0: drain before serving multitenant
dispatch (pre-tenancy args fail closed, correct but noisy); (2)
single→multi on populated tables: backfill the tenant attribute first
(NULL-tenant rows form a shadow partition that strands effect-once),
then regenerate identity indexes, then enable.

## 1.1.1 (September 16, 2026)

Tri-OS proof release. No covered-surface change: the
package now carries mechanical proof of macOS, Linux, and Windows
support; a dedicated CI leg per OS runs the full 555-test suite on
the dev-default toolchain, all nine legs green, and the README claims
exactly the OSes the legs prove.

### Added

- CI legs on macOS and Windows (dev-default toolchain Elixir 1.20.4 /
  OTP 28, `compile --warnings-as-errors` + the full suite). Linux was
  already proven by every existing leg.
- `.gitattributes` (`* text=auto eol=lf`): every OS checks out
  byte-identical sources; all tracked files were already LF, so no
  renormalization was needed.

### Fixed

- Four test-side portability defects exposed by the first Windows run
  (the package and its sqlite NIF substrate compiled and ran on
  Windows throughout; every defect was in fixtures):
  - two `:inets` httpd fixtures hardcoded `server_root: "/tmp"`,
    nonexistent on Windows; one failure hid as a `setup_all`
    invalidation that silently excludes a whole module's tests from
    the failed count; both now use `System.tmp_dir!()`;
  - CRLF checkout on Windows broke the install-task fixture's byte
    assertions (`=~ "plug Plug.Parsers\n"` vs `"\r\n"` bytes);
  - httpd's URL→path translation mangles backslashes, so every request
    returned 500 on Windows; the fixtures now hand httpd
    forward-slash `server_root`/`document_root` (a no-op on unix).

## 1.1.0 (September 16, 2026)

Support-window release: the Elixir floor rises to 1.20 (a minor, not a
major, by the public support policy, in the first exercise of that rule), the
repo's own toolchain becomes self-enforcing and lockstep-pinned, and
locked Oban is updated to 2.24.1, Dialyxir to 1.4.8, and ExDoc to 0.40.4,
with `mix hex.audit` running in CI.

### Changed

- The supported Elixir window is now `~> 1.20` (was `~> 1.17`);
  nothing below Elixir 1.20 is supported; the OTP
  floor is 28 (CI tests 28 and 29). Consumers on 1.17–1.19 get a
  resolver-level refusal instead of a compile. The public support policy makes a
  supported-floor bump a MINOR release, so a `~> 1.0` pin resolves
  1.1.0 and then fails resolution on old Elixirs. Pin
  `{:ash_hooks, "~> 1.0.4"}` until you can move (see UPGRADING.md). CI
  tests the window on Erlang/OTP 28 (the dev default, pinned in
  `.tool-versions` and mirrored by a dedicated leg) and 29; the floor
  leg drops the lock and resolves at the floor to keep the requirement
  honest.
- Repo-local toolchain enforcement. Consumers are unaffected: `config/`
  is excluded from the hex tarball. Development runs on one pinned
  toolchain (`.tool-versions`: Elixir 1.20.4 / Erlang/OTP 28) mirrored
  by a dedicated CI leg; `config/config.exs` refuses any OTP release CI
  does not test (currently 28/29) before anything compiles, because
  `System.version/0` does not encode the OTP build and a same-Elixir
  foreign build would otherwise compile incompatible BEAMs silently.
  The window, `.tool-versions`, the OTP allowlist, and the CI matrix
  move together in ONE commit. `mix hex.audit` now runs in CI on every
  push.
- Updated locked dependencies: Oban 2.23.1 → 2.24.1, Dialyxir 1.4.7 → 1.4.8, ExDoc
  0.40.3 → 0.40.4. `mix hex.audit` clean before and after (and OSV shows
  no advisories against the three new versions).

### Fixed

- A `%Regex{}` inside a module attribute (`@redaction_patterns`) embeds
  the compiled `re_pattern`, which is a reference on OTP 28; Elixir
  < 1.19 cannot escape references when injecting an attribute into a
  function body, so the package did not compile for consumers on
  1.17–1.19 × OTP 28 (a combination the old window admitted). The
  patterns are now built by a `defp` (identical regexes, flags, and
  order); with the floor now at 1.20 that combination is out-of-window,
  and the `defp` keeps the escape class dead if the floor ever drops
  below 1.19.
- `mix dialyzer` on a fresh PLT no longer reports 13 unknown-function/
  unknown-type warnings in `test/support`: `use AshSqlite.Repo` emits
  `Ecto.Adapters.SQL` delegations, and the deps-PLT app enumeration does
  not reliably include `:ecto_sql`; it is now explicit in
  `plt_add_apps` with the reason inline.

### Added

- `scripts/check-currency.sh`: exits nonzero whenever `mix hex.outdated`
  shows resolvable drift, and prints the packages whose latest release the
  resolver will not take under current requirements; each of those must
  carry an inline deliberate-pin reason in `mix.exs`. Fail-closed: an
  errored `hex.outdated` run (lock mismatch, resolver failure) also exits
  nonzero.

## 1.0.4 (September 16, 2026)

Current-Ash compatibility release: the repo's own app surfaces carry Ash
3.33's required `default_string_length_count`, and the byte-bound
correction family that requirement exposed is fixed.

### Fixed

- Fixed byte-length validation for event identifiers, response snippets, and error summaries:
  - `Event.new/1` and the dispatcher's event guards bound ids/types by
    BYTES, not `String.length` (graphemes); under Ash 3.33 `:codepoints`,
    a 128-grapheme combining-character type (512 bytes) passed validation
    and then failed every endpoint's `:dispatch` create. The inbound side
    already bounded bytes; outbound now matches, in either counting mode.
  - A thrown 255-character token no longer overflows `last_error`:
    `"throw: " <> classify_token(...)` could reach 262 bytes and fail the
    enqueue-failure ledger write itself (mode-independent, ASCII); the
    combined string is capped now, like the `:exit` sibling.
  - An inbound handler failing with an invalid-UTF-8 binary no longer
    loses its failure record: the error class collapses to the
    redaction floor's `[binary]` placeholder instead of failing the
    `:mark_failed` write and leaving the delivery re-drivable.
- Captured snippets and error summaries are now capped in BYTES instead of
  grapheme-sliced. Under Ash 3.33's `:codepoints` counting the injected
  `max_length` constraints count codepoints, and a grapheme-sliced
  2048-character snippet of combining characters spans 4000+ codepoints;
  the post-send ledger write then violated its own constraint and crashed
  (`mark_succeeded` failed on a hostile response body), the same re-send
  poison class the control-byte strip closes. The byte cap (on a codepoint
  boundary) bounds the value under every counting mode, on every supported
  Ash. Covers the response-snippet capture path, the redaction floor, and
  the inbound `error_class` / dispatcher exit-string bounds. Regression tests cover combining-character inputs that exceeded stored
  value limits.
- Current-Ash compatibility: Ash 3.33 requires every application that
  compiles resources to set `config :ash, :default_string_length_count`
  (the app-level half of GHSA-cwjv-574p-59f6), which broke the CI floor
  and Livebook legs; both resolve Ash lock-free at latest and failed
  resource compilation. The test application (`config/test.exs`,
  repo-local and never shipped), the get-started Livebook, and the
  tutorial now carry the setting. The package itself still writes no
  `:ash` configuration; consumers keep that choice, and both documented
  values work (see UPGRADING.md). A new tripwire test locks the boundary:
  `lib/` never writes `:ash` application environment.
- The tutorial's requirements line now matches the tested floor (Elixir
  `~> 1.17`; the `~> 1.15` claim was disproven by the CI floor leg, per
  the public support policy).

### Changed

- `mix.lock`: ash 3.33.4, and the dev/test substrate cleared of its
  published advisories (ash_sqlite 0.2.19 / ash_sql 0.7.5, both test-only and
  never shipped in the package; `mix hex.audit` is now clean).

## 1.0.3 (August 23, 2026)

Docs-and-tests release (no functional changes; 1.0.2's gate and fixes
unchanged):

### Changed

- The send-failure contract tests dropped their 512MB bodies for 16MB
  with the peer's receive window pinned to 1KB, preserving the same in-flight
  send-failure check with lower memory use. CI uploads the cover HTML when
  the coverage gate reds (triage data, not guesswork).

### Docs

- UPGRADING carries the 1.0.2 behavior notes (the `:httpc` literal-IP
  HTTPS refusal, the `:http_opts` threading).
- The `:httpc` and `Bounded` moduledocs document the literal-IP posture
  and `:cacerts` trust-store configuration.

## 1.0.2 (August 22, 2026)

CI now requires 100% line coverage in the coverage surface declared in `mix.exs`.

### Added

- `Target.ssl_options/2` and both HTTP adapters accept an injectable
  `:cacerts` trust bundle (`[cacerts: der_list]` in the adapter opts,
  or `use AshHooks.Worker, http_opts: ...` on the Oban path): pin a
  private CA for private-CA endpoints. Default UNCHANGED (the OTP CA
  store). The worker's `http_opts` takes compile-time literals, or an
  `{m, f, a}` resolved per-perform for computed bundles.
- TLS success paths are covered by REAL CA-verified loopback sessions
  against committed local fixtures, including the literal-IP iPAddress-SAN
  floor and its fail-closed mismatch.

### Fixed

- `AshHooks.Http.CertSan.ip_san_match?/2` fails closed (returns `false`)
  instead of CRASHING its caller when a certificate's SAN extension
  carries non-DER bytes: asn1's decode EXITS on invalid tags, which the
  previous error-only rescue could not catch.
- `AshHooks.Http.Httpc` (the alternate adapter) refuses literal-IP HTTPS
  destinations with `{:error, :ip_literal_https_needs_bounded}`: it
  never holds the socket, so the iPAddress-SAN floor cannot run there
  and chain-validation alone would let any chain-valid certificate
  authenticate the endpoint IP. Use `AshHooks.Http.Bounded` (the
  default) for literal-IP HTTPS endpoints.
- `use AshHooks.Worker` threads `:http_opts` into the delivery config
  (the option was previously accepted and silently dropped).

### Changed

- `mix test --cover` GATES at 100% line coverage of `lib/`'s
  runtime-reachable lines (CI fails on a miss). The ignore list carries
  exactly the `:cover`-invisible classes: Spark's generated DSL
  sections, test-support modules, and four compile-window module-body
  lines. 31 provably-dead defensive arms were DELETED with proofs
  (commit d6f3788) rather than exempted; the shipped surface behaves
  identically.

## 1.0.1 (August 22, 2026)

Documentation and tests release with no functional changes. Added
concurrent-ingest and HTTP-buffering regression tests:

### Added

- The fenced ledger's exactly-once claim is now pinned by a TRUE
  concurrent race test (8 simultaneous same-key ingests on a
  3-connection sqlite pool: exactly one `:created`, one row), and the
  same race without the storage unique index proves the failure mode:
  sqlite fails CLOSED with a loud storage error, zero rows. The
  `InboundDelivery` moduledoc cites both.
- The `:httpc` adapter's giant-non-2xx window is now MEASURED (dribble
  probe: ~4.65MB transient for a 4MB error body against a 16-byte
  bound) with a committed containment test pinning the final cut;
  the public support policy carries the numbers.

### Fixed

- The missing-index hazard is documented accurately: on storage layers
  with native conflict support (sqlite, postgres) a missing unique
  index errors the ingest loudly; the previously documented
  "two rows, both `:created`" shape applies to degraded-upsert layers.
  The as-built floor is stronger than the docs claimed.

## 1.0.0 (August 22, 2026)

1.0.0 is the semantic-versioning baseline: no public API
removals or renames from 0.2.0 through 0.2.2. Three behavior corrections follow;
see migration notes in [UPGRADING.md](UPGRADING.md).

### Fixed

- **Truncated chunked responses no longer classify as success.** The
  default HTTP adapter returned a partial body as `{:ok, ...}` when a
  chunked response was cut by early close; a 2xx on partial bytes
  could mark a delivery `:succeeded`. Chunked now returns
  `{:error, :truncated_body}` exactly like the Content-Length framing,
  and the driver retries.
- **The literal-IP https certificate check actually works now.** The
  iPAddress-SAN matcher was unreachable since birth (found by the new
  dialyzer gate): every literal-IP https endpoint was rejected
  fail-closed with `:cert_ip_mismatch`. Extracted to the
  tested `AshHooks.Http.CertSan`. Both address families now verify against
  certificates.
- **A hostile chunked response can no longer balloon worker memory.**
  The chunk consumer accumulated the ENTIRE attacker-declared chunk
  before trimming to the body bound; an 8MB declaration held ~16.8MB
  in the worker against a 16-byte bound. Consumption is now phase-bounded: keep at most the
  allowance, discard the excess slice-wise (one receive slice held at a
  time), and a chunk terminator that is not CRLF is now
  `{:error, :malformed_chunked}` instead of being silently consumed
  (a malformed 2xx can no longer classify as succeeded). Run-on
  chunk-size lines without a terminator are refused past a sane bound
  instead of being buffered.
- `AshHooks.Delivery.prune/2` returns `{:error, error}` when the
  resource lacks `inserted_at`, following the same contract as
  `AshHooks.Ingress.prune/2` its `@spec` always promised (previously
  raised `ArgumentError`).

### Added

- **Semver and support policy**: the covered public surface
  is named, deprecations run two minors, and the minimum supported
  versions are CI-tested (Elixir ~> 1.17 / Erlang/OTP 27 / Ash ~> 3.0 /
  Oban ~> 2.20 optional). The previously claimed Elixir 1.15 floor was
  never buildable with current Ash and is corrected here; 1.0.0 is
  the first release whose floor is actually tested.
- **SECURITY.md** with a private disclosure channel (GitHub private
  vulnerability reporting, enabled), scope, and known posture notes;
  **CONTRIBUTING.md** and **UPGRADING.md**. All three ship in the
  tarball and render on hexdocs.
- **Dialyzer gate** on the public API (local + CI): the first run caught
  the dead IP-SAN matcher above.
- **CI**: a floor leg resolving dependencies at the declared minimums
  (it disproved the old 1.15 claim on its first run), a package leg checking the hex tarball ships
  every documentation file and that the DSL cheat sheets match the
  DSL, and an advisory coverage report.
- `@spec` on the HTTP behavior's `request/5` (both adapters),
  `AshHooks.dispatch/4`, the resource extensions'
  `statuses/0`/`signing_modes/0` (now documented), and the
  internal HTTP target-resolution helpers.
- A dedicated extension-shape test suite for `AshHooks.OutboundDelivery`,
  pinning the injected attributes, the `unique_delivery` identity, and
  the `:dispatch` no-touch-upsert contract.

### Changed

- **Read posture documented honestly**: read
  access to the ledger/delivery resources is consumer-governed; the
  package injects no read policies. README → Security carries the
  deny-by-default policy recipe; the resource moduledocs now carry
  READ-EXPOSURE warnings. (No code change: reads were always
  consumer-governed; the docs previously implied otherwise.)
- Install guidance is `{:ash_hooks, "~> 1.0"}`; the README (previously
  pinned `~> 0.1.0`, one feature-release behind) and tutorial both
  corrected, with the install-constraint check added to the release
  checklist.

## 0.2.2 (August 22, 2026)

### Fixed

- usage-rules.md now ships in the hex tarball (the Ash AI-assistant
  convention reads it from the package) and renders on hexdocs. It was
  previously GitHub-only.

## 0.2.1 (August 22, 2026)

### Added

- A runnable get-started Livebook (guided tour: inbound verify/dedup,
  a live local delivery, telemetry, retention), verified headless in CI
  on every push. No functional changes.

## 0.2.0 (August 22, 2026)

### Added

- Retention hooks: `AshHooks.Ingress.prune/2`
  and `AshHooks.Delivery.prune/2` (terminal rows older than a cutoff,
  keyed on the resource's `timestamps()`; non-terminal rows never
  deleted), and `AshHooks.Ingress.redact_payload/4` (payload
  field-redaction under the claim fence; the original-bytes digest is
  preserved). Deleting a terminal row re-opens its dedup identity;
  set TTLs beyond replay/re-emission horizons.

## 0.1.1 (August 22, 2026)

### Changed

- README rewritten as a package front door (no functional changes):
  audience/register pass; internal build references removed.

## 0.1.0 (August 22, 2026)

### Added

- Inbound machine: `AshHooks` + `AshHooks.InboundDelivery` extensions,
  `AshHooks.Ingress` (verify-before-trust, fenced unique-ingest dedup
  ledger, lease-based claim, crash-window re-drive), provider behavior
  with ComplyCube/HubSpot v3 references and a test provider.
- Outbound machine: `AshHooks.dispatch/4` fanout with per-endpoint
  isolation and enqueue-repair CAS; `AshHooks.OutboundDelivery`,
  `AshHooks.Subscription`, `AshHooks.Endpoint` extensions.
- Delivery runtime (`AshHooks.Delivery`) + host-injected
  `use AshHooks.Worker`: Standard Webhooks signing (standard/dual/legacy
  envelopes), row-owned retry policy (Retry-After, jittered backoff,
  dead-letter ceiling), 410 durable disable, redirect refusal, send-time
  SSRF re-check.
- `AshHooks.Http` adapter behavior with a memory-bounded native
  HTTP/1.1 default (`AshHooks.Http.Bounded`, with every read capped under
  all framings) and an OTP `:httpc` alternative.
- Response-snippet redaction floor: no body bytes
  by default (fixed-grammar status + allowlisted content-type summary);
  per-call `snippet_capture` opt-in under the in-package redaction
  floor (NFKC homoglyph folding, bounded-fixpoint decode chain,
  separator-tolerant markers, ≥16-char union-alphabet entropy rule);
  fail-closed consumer `snippet_redactor` callback; `[captured]`
  marking.
- Telemetry (the public support policy floor: ids/integers/fixed atoms/classified
  reasons only, never secrets or bodies): ingress verify/dedup/claim,
  dispatch enqueue_failed, delivery attempt/result/backoff/dead_letter/
  disable; `AshHooks.Telemetry.fingerprint/1`.
- Igniter installer, DSL cheat sheets, get-started tutorial,
  usage-rules.md.

### Security

- Package floors shipped in-code: secrets as sources only
  (literals rejected at parse), default-deny machine-written ledger
  fields, SSRF guard at registration and send, NO headers stored on
  either ledger at all, no response-body persistence by default,
  classified-only error strings.
