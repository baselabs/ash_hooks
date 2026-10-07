# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## Unreleased

## 2.0.1 — October 6, 2026

The first published 2.x release includes the delivery ownership, recovery, and
migration changes below. The guided tour keeps protocol implementations available
for resources defined during notebook evaluation.

### Fixed

- Disable protocol consolidation in the Livebook setup so dynamically defined Ash
  resources use their custom display without consolidation warnings.
- Update the notebook, release tooling, and production consumer to 2.0.1.

## 2.0.0 — October 6, 2026

Source candidate; superseded by 2.0.1 before Hex publication. The Git tag is retained.

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
- Candidate archive inspection and notebook execution precede publication; the
  normal notebook then executes against the exact published version.
- Documentation changes trigger Linux CI. The minimum-consumer leg pins Ash
  3.34.3; package, PostgreSQL, coverage, and Livebook checks feed `all-checks-pass`.

## 1.3.0 — October 5, 2026

Additive options for domain naming and lifecycle, a compile
fix for generated (non-writable) primary keys, typed subscription
matching, loud documentation of the policy/id/adapter obligations, and a
Linux CI leg exercising an AshPostgres `uuid_v7` consumer shape.

### Added (additive options — non-breaking per ADR-0010)

- **`payload_attribute` on the `outbound_delivery` section.** The exact
  payload-bytes column's name is configurable (default `:payload`):
  rename it when the consumer's domain reserves `payload` for its own
  sole payload store. The injected column, the `:dispatch` accept list,
  and every signing/sending read follow the configured name; a name
  colliding with another injected field fails closed at compile.
- **`prune_action :none` on the `outbound_delivery` section.** Opt out
  of the retention `destroy :prune` action's injection for append-only
  audit ledgers (no destroy action exists on the resource at all);
  `AshHooks.Delivery.prune/2` then fails loud with a named error —
  deletion is the consumer's own surface. Default `:destroy` is
  unchanged.
- **`status_attribute` / `enabled_values` / `disabled_value` on the new
  `endpoint` section.** Map the durable enable/disable onto the
  consumer's OWN switch (e.g. an `active` boolean): `status` is then
  not injected — one switch, so the consumer's off switch and the
  package's can never silently disagree. The dispatcher's skip and the
  send path's dead-letter both route through `AshHooks.Endpoint.enabled?/1`;
  the 410 auto-disable flips the mapped attribute. The mapped attribute
  must be consumer-declared (fail-closed at compile).
- **A Linux CI leg with a Postgres service** exercising the transformers
  against an AshPostgres, uuid_v7-keyed, sole-store-payload consumer
  shape (`postgres` job; the suite is env-gated by `ASH_HOOKS_POSTGRES=1`
  and excluded from ordinary dev runs). `ash_postgres` is a dev/test-only
  dependency — never ships, never constrains consumers.

### Fixed

- **`:dispatch`/`:ingest` no longer accept `:id` on resources whose
  primary key is a non-writable `:id`** (e.g. `uuid_v7_primary_key`):
  Ash's `ValidateAccept` raised at compile on exactly that consumer
  shape, making the extensions unadoptable without replacing the PK.
  The accept lists carry `:id` only when the PK is a writable `:id`
  (the package-injected default — byte-identical classification); the
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
  enqueuer's own fence — the default Oban enqueuer's
  endpoint_id+event_uuid job uniqueness, or the consumer's own dedup
  for a custom `enqueue:`. ADR-0010 note: the injected action accept
  lists are covered surface — this is a behavior correction (the
  previous accept list required a writable PK that consumers with
  generated PKs cannot provide), not a removal; no working consumer can
  regress (the shape did not compile).
- **Covered-surface tightening alongside the H4 mapping: the send path
  dead-letters an endpoint whose status is anything other than
  `:enabled`** (previously only an exact `:disabled` dead-lettered, so a
  consumer-redeclared `status` with extra values delivered). The
  dispatcher's skip and the send path now route through the ONE
  `AshHooks.Endpoint.enabled?/1` check — fail-closed by design.
- **`AshHooks.Subscription.matches?/2` normalizes `event_types` entries
  with `to_string/1`.** An atom-typed register (`{:array, :atom}` — a
  closed enum) previously matched NOTHING: zero deliveries, no error.
  Atom and string entries (and the `"*"`/`:"*"` wildcard in either
  representation) now match identically. Consumers redeclaring
  `event_types` keep their own constraints — the injected `["*"]`
  default is not forced on them.

### Changed

- **CI is Linux-only; the macOS and Windows build legs are removed.**
  Tri-OS stays a developer-portability requirement (clone, set up, and
  test must work on every OS) — it was never meant to be a CI topology,
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
  consumer-owned policy obligation is stated loudly — the inbound half's
  "you write your own" posture, mirrored outbound. The seven delivery
  actions plus the endpoint's `:disable`.
- **Deterministic `Event.id` guidance** (`Event`, `Dispatcher`
  moduledocs): derive the id from the artifact's stable id — a generated
  id turns every producer re-fire into a duplicate POST per sweep.
- **The adapter-author contract** (`AshHooks.Http` moduledoc): headers
  must be a LIST of `{name, value}` tuples (a map silently loses
  `Retry-After`), and the resolve-once/connect-pinned obligation that
  closes the DNS-rebinding TOCTOU is the adapter's, with the driver's
  send-time check as the residual.
- **`retry_after_cap_seconds` semantics** (`Worker` moduledoc): the
  86,400 default is receiver-held-state budget — up to 24 hours per
  attempt on one header; lower it for an exhaust-fast posture.
- **The 410 auto-disable posture** (`Delivery` moduledoc): an
  unattributed system bulk write by design (no actor in a versioned
  register), no built-in tenant-facing signal — a receiver that answers
  410 once goes dark silently unless the app wires the
  `[:ash_hooks, :delivery, :disable]` telemetry event or accepts the
  posture in writing.

## 1.2.1 — September 24, 2026

### Fixed

- **The documentation tree now ships in the hex tarball.** 1.2.0's package
  carried only the top-level docs (README, CHANGELOG, UPGRADING, usage-rules),
  so `documentation/` — including the multi-tenant adoption checklist — was
  reachable only on GitHub/hexdocs while UPGRADING.md and the CHANGELOG
  referenced it by repo-relative path. Installed-package readers now get the
  tutorials (get-started, tenancy-adoption-checklist), the DSL reference, and
  the Livebook alongside those references. No library code changed; hexdocs
  and the package page README are unaffected.

## 1.2.0 — September 24, 2026

Tenancy release (ADR-0011, additive and opt-in): ash_hooks aligns with
Ash attribute multitenancy — an explicit tenant threads every data call,
and the package fails closed with named errors before any data access
when a multitenant resource is touched without one. Single-tenant
adopters change nothing: the entire pre-1.2 suite passes unchanged over
tenant-less fixtures inside the now-610-test gate, because threading a
tenant through resources with no multitenancy declaration is
mechanically inert.

### Added

- **Tenant threading on every path** — `AshHooks.dispatch/4` (`:tenant`
  opt), `AshHooks.Ingress.ingest/4` (`ctx[:tenant]`), the claim/mark/
  renew/redact/prune/reap heads (`:tenant` opt, new optional arity),
  `AshHooks.Delivery.run/2` (tenant recovered from job args), and both
  prunes. The tenancy contract: consumers declare
  `multitenancy :attribute, attribute: <same attr>` on the resources a
  given operation touches; the package verifies that set on every entry
  point and returns `{:error, :tenant_required}` /
  `{:error, :tenancy_mismatch}` before any data access (Ash's native
  fail-closed stays the backstop; `global?: true` is rejected — it
  silently disables fail-closed reads). A compile-time verifier
  additionally rejects `multitenancy :bypass`, `:bypass_all`, and
  `:allow_global` actions on multitenant package resources.
- **Per-tenant operations** — `AshHooks.reap_all/2` and
  `AshHooks.prune_all/2` sweep a tenant enumerable sequentially with
  per-tenant error isolation and totals
  (`{:ok, %{results: %{tenant => {:ok, n} | {:error, reason}}, total: n}}`).
- **`AshHooks.reconcile_pending/3`** — the supported reconciliation for
  delivery rows stranded at `:pending` by a crash between row write and
  enqueue: a WHERE-gated CAS flip to `:enqueue_failed` (real state
  change — matched-records is the win signal; exactly one winner per
  row among concurrent reconcilers, proven under a custom non-Oban
  seam), then enqueue through the same seam dispatch takes. Exactly-once
  ACROSS claim mechanisms (reconciliation vs re-dispatch repair) is the
  enqueue seam's contract — the canonical Oban seam's job uniqueness
  provides it; a custom seam must be idempotent itself.
- **Tenant-aware secret resolution (all optional)** — the worker macro's
  `:tenant_aware_secrets` (2-arity `f(ref, tenant)` resolver contract);
  the inbound `secret fn tenant -> ... end` source; the provider
  behavior's optional `webhook_signing_secret/2`
  (Organization × connection custody; `use AshHooks.Provider` ships an
  overridable default delegating to `/1`); and `:tenant` in the
  `verify_signature/3` context map.
- **Oban args carry the tenant** — the generated `enqueue/2` serializes
  the row's tenant (string tenants are the supported shape; non-string
  tenants must round-trip `parse_attribute` over JSON); uniqueness keys
  stay `[:endpoint_id, :event_uuid]`, and a pre-tenancy tenant-less job
  still conflicts with the tenant-bearing job on the same pair (proven
  on the real Oban engine).
- The dispatch result contract is now a public typespec
  (`t:AshHooks.Dispatcher.dispatch_result/0`) including the new
  `:reconciled` status.
- The multi-tenant adoption checklist
  (documentation/tutorials/tenancy-adoption-checklist.md) and ADR-0011.

### Migration notes

Two adopter classes see action; single-tenant staying single-tenant
sees none. See UPGRADING.md and the adoption checklist: (1) cutover
with in-flight 1.1.x Oban jobs — drain before serving multitenant
dispatch (pre-tenancy args fail closed, correct but noisy); (2)
single→multi on populated tables — backfill the tenant attribute first
(NULL-tenant rows form a shadow partition that strands effect-once),
then regenerate identity indexes, then enable.

## 1.1.1 — September 16, 2026

Tri-OS proof release. No covered-surface change (patch, ADR-0010): the
package now carries mechanical proof of macOS, Linux, and Windows
support — a dedicated CI leg per OS runs the full 555-test suite on
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
  Windows throughout — every defect was in fixtures):
  - two `:inets` httpd fixtures hardcoded `server_root: "/tmp"`,
    nonexistent on Windows — one failure hid as a `setup_all`
    invalidation that silently excludes a whole module's tests from
    the failed count; both now use `System.tmp_dir!()`;
  - CRLF checkout on Windows broke the install-task fixture's byte
    assertions (`=~ "plug Plug.Parsers\n"` vs `"\r\n"` bytes);
  - httpd's URL→path translation mangles backslashes, so every request
    returned 500 on Windows — the fixtures now hand httpd
    forward-slash `server_root`/`document_root` (a no-op on unix).

## 1.1.0 — September 16, 2026

Support-window release: the Elixir floor rises to 1.20 (a minor, not a
major, by ADR-0010 rule 4 — the first exercise of that rule), the
repo's own toolchain becomes self-enforcing and lockstep-pinned, and
dependencies sit at latest with `mix hex.audit` running in CI.

### Changed

- The supported Elixir window is now `~> 1.20` (was `~> 1.17`) —
  nothing below Elixir 1.20 is supported, by owner decision; the OTP
  floor is 28 (CI tests 28 and 29). Consumers on 1.17–1.19 get a
  resolver-level refusal instead of a compile. ADR-0010 rule 4 makes a
  supported-floor bump a MINOR release, so a `~> 1.0` pin resolves
  1.1.0 and then fails resolution on old Elixirs — pin
  `{:ash_hooks, "~> 1.0.4"}` until you can move (see UPGRADING.md). CI
  tests the window on Erlang/OTP 28 (the dev default, pinned in
  `.tool-versions` and mirrored by a dedicated leg) and 29; the floor
  leg drops the lock and resolves at the floor to keep the requirement
  honest.
- Repo-local toolchain enforcement — consumers are unaffected: `config/`
  is excluded from the hex tarball. Development runs on one pinned
  toolchain (`.tool-versions`: Elixir 1.20.4 / Erlang/OTP 28) mirrored
  by a dedicated CI leg; `config/config.exs` refuses any OTP release CI
  does not test (currently 28/29) before anything compiles, because
  `System.version/0` does not encode the OTP build and a same-Elixir
  foreign build would otherwise compile incompatible BEAMs silently.
  The window, `.tool-versions`, the OTP allowlist, and the CI matrix
  move together in ONE commit. `mix hex.audit` now runs in CI on every
  push.
- Dependencies moved to latest (`mix hex.outdated` shows zero "Update
  possible"): oban 2.23.1 → 2.24.1, dialyxir 1.4.7 → 1.4.8, ex_doc
  0.40.3 → 0.40.4. `mix hex.audit` clean before and after (and OSV shows
  no advisories against the three new versions).

### Fixed

- A `%Regex{}` inside a module attribute (`@redaction_patterns`) embeds
  the compiled `re_pattern`, which is a reference on OTP 28 — Elixir
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
  not reliably include `:ecto_sql` — it is now explicit in
  `plt_add_apps` with the reason inline.

### Added

- `scripts/check-currency.sh`: exits nonzero whenever `mix hex.outdated`
  shows resolvable drift, and prints the packages whose latest release the
  resolver will not take under current requirements — each of those must
  carry an inline deliberate-pin reason in `mix.exs`. Fail-closed: an
  errored `hex.outdated` run (lock mismatch, resolver failure) also exits
  nonzero.

## 1.0.4 — September 16, 2026

Current-Ash compatibility release: the repo's own app surfaces carry Ash
3.33's required `default_string_length_count`, and the byte-bound
correction family that requirement exposed is fixed.

### Fixed

- Delta-review completions of the byte-bound invariant, each red-proven:
  - `Event.new/1` and the dispatcher's event guards bound ids/types by
    BYTES, not `String.length` (graphemes) — under Ash 3.33 `:codepoints`,
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
  2048-character snippet of combining characters spans 4000+ codepoints —
  the post-send ledger write then violated its own constraint and crashed
  (`mark_succeeded` failed on a hostile response body), the same re-send
  poison class the control-byte strip closes. The byte cap (on a codepoint
  boundary) bounds the value under every counting mode, on every supported
  Ash. Covers the response-snippet capture path, the redaction floor, and
  the inbound `error_class` / dispatcher exit-string bounds. Found by
  mining a timed-out cross-vendor review probe; regression is red-proven
  against the grapheme-sliced code.
- Current-Ash compatibility: Ash 3.33 requires every application that
  compiles resources to set `config :ash, :default_string_length_count`
  (the app-level half of GHSA-cwjv-574p-59f6), which broke the CI floor
  and Livebook legs — both resolve Ash lock-free at latest and failed
  resource compilation. The test application (`config/test.exs`,
  repo-local and never shipped), the get-started Livebook, and the
  tutorial now carry the setting. The package itself still writes no
  `:ash` configuration — consumers keep that choice, and both documented
  values work (see UPGRADING.md). A new tripwire test locks the boundary:
  `lib/` never writes `:ash` application environment.
- The tutorial's requirements line now matches the tested floor (Elixir
  `~> 1.17`; the `~> 1.15` claim was disproven by the CI floor leg, per
  ADR-0010).

### Changed

- `mix.lock`: ash 3.33.4, and the dev/test substrate cleared of its
  published advisories (ash_sqlite 0.2.19 / ash_sql 0.7.5 — test-only,
  never shipped in the package; `mix hex.audit` now clean).

## 1.0.3 — August 23, 2026

Docs-and-tests release (no functional changes; 1.0.2's gate and fixes
unchanged):

### Changed

- The send-failure contract tests dropped their 512MB bodies for 16MB
  with the peer's receive window pinned to 1KB — the same in-flight
  guarantee at 1/32nd the allocation, closing the resource-pressure
  residual from the 1.0.2 ship report. CI uploads the cover HTML when
  the coverage gate reds (triage data, not guesswork).

### Docs

- UPGRADING carries the 1.0.2 behavior notes (the `:httpc` literal-IP
  HTTPS refusal, the `:http_opts` threading).
- The `:httpc` and `Bounded` moduledocs document the literal-IP posture
  and the `:cacerts` trust-store seam; ADR-0009 records the seam
  decision (wayfinder D3) in Consequences.

## 1.0.2 — August 22, 2026

The 100% coverage release: the maintainership directive (2026-08-22)
superseding 1.0.1's print-only posture, worked through the wayfinder
decisions (#20-#22) — line coverage of `lib/` now GATES in CI, and the
release carries the surfaces that build required.

### Added

- `Target.ssl_options/2` and both HTTP adapters accept an injectable
  `:cacerts` trust bundle (`[cacerts: der_list]` in the adapter opts —
  on the Oban path, `use AshHooks.Worker, http_opts: ...`): pin a
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
  default) for literal-IP HTTPS endpoints. Cross-vendor-reviewed
  (both peers), pre-existing hazard class.
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

## 1.0.1 — August 22, 2026

Docs-and-tests release (no functional changes). The 1.0.0 ship report's
three residual postures are probed and pinned instead of documented:

### Added

- The fenced ledger's exactly-once claim is now pinned by a TRUE
  concurrent race test (8 simultaneous same-key ingests on a
  3-connection sqlite pool: exactly one `:created`, one row) — and the
  same race without the storage unique index proves the failure mode:
  sqlite fails CLOSED with a loud storage error, zero rows. The
  `InboundDelivery` moduledoc cites both.
- The `:httpc` adapter's giant-non-2xx window is now MEASURED (dribble
  probe: ~4.65MB transient for a 4MB error body against a 16-byte
  bound) with a committed containment test pinning the final cut;
  ADR-0009 carries the numbers.

### Fixed

- The missing-index hazard is documented accurately: on storage layers
  with native conflict support (sqlite, postgres) a missing unique
  index errors the ingest loudly — the previously documented
  "two rows, both `:created`" shape applies to degraded-upsert layers.
  The as-built floor is stronger than the docs claimed.

## 1.0.0 — August 22, 2026

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
- `@spec` on the HTTP behavior's `request/5` (both adapters),
  `AshHooks.dispatch/4`, the resource extensions'
  `statuses/0`/`signing_modes/0` (now documented), and the
  internal HTTP target-resolution helpers.
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

## 0.2.2 — August 22, 2026

### Fixed

- usage-rules.md now ships in the hex tarball (the Ash AI-assistant
  convention reads it from the package) and renders on hexdocs. It was
  previously GitHub-only.

## 0.2.1 — August 22, 2026

### Added

- A runnable get-started Livebook (guided tour: inbound verify/dedup,
  a live local delivery, telemetry, retention) — CI-verified headless
  on every push. No functional changes.

## 0.2.0 — August 22, 2026

### Added

- Retention hooks (ADR-0005 floor completed): `AshHooks.Ingress.prune/2`
  and `AshHooks.Delivery.prune/2` (terminal rows older than a cutoff,
  keyed on the resource's `timestamps()`; non-terminal rows never
  deleted), and `AshHooks.Ingress.redact_payload/4` (payload
  field-redaction under the claim fence; the original-bytes digest is
  preserved). Deleting a terminal row re-opens its dedup identity —
  set TTLs beyond replay/re-emission horizons.

## 0.1.1 — August 22, 2026

### Changed

- README rewritten as a package front door (no functional changes):
  audience/register pass; internal build references removed.

## 0.1.0 — August 22, 2026

### Added

- Inbound machine: `AshHooks` + `AshHooks.InboundDelivery` extensions,
  `AshHooks.Ingress` (verify-before-trust, fenced unique-ingest dedup
  ledger, lease-based claim, crash-window re-drive), provider behavior
  with ComplyCube/HubSpot v3 references and a test provider.
- Outbound machine: `AshHooks.dispatch/4` fanout with per-endpoint
  isolation and enqueue-repair CAS; `AshHooks.OutboundDelivery`,
  `AshHooks.Subscription`, `AshHooks.Endpoint` extensions.
- Delivery runtime (`AshHooks.Delivery`) + host-injected
  `use AshHooks.Worker`: Standard-Webhooks signing (standard/dual/legacy
  envelopes), row-owned retry policy (Retry-After, jittered backoff,
  dead-letter ceiling), 410 durable disable, redirect refusal, send-time
  SSRF re-check.
- `AshHooks.Http` adapter behavior with a memory-bounded native
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
