# Roadmap

ash_hooks gives Ash applications verified, deduplicated inbound webhooks and signed, durably
delivered outbound webhooks, for every tenant of a multi-tenant application, while the
application keeps its own resources, policies, keys and scheduling. Each release ships with its
documentation, tutorials and Livebook current and run, and is published to Hex on the
maintainer's approval. This file is the one queue of the project's work; the
[changelog](../CHANGELOG.md) records what each release shipped and [docs/adr](adr) records the
decisions behind it.

## Status board

<!-- status-board:start -->
One line per row, grouped by status; badges follow verified evidence at `main`; the drift test is
`test/ash_hooks/records_test.exs`. Updated November 15, 2026.

| Badge | Meaning |
|---|---|
| ✅ | Done and verified: landed, and the row records live, hosted or full-lifecycle evidence with no open item inside its claim |
| 🟢 | Done, not verified: landed, but the evidence is local or partial, or live, peer or production proof is still owed |
| 🟡 | Partly done: some increments landed, scoped work remains |
| 🔵 | Designed, ready to build: a judged design input or ADR with stated acceptance, nothing landed |
| ⚪ | Needs design: only a charter, strategy or posture reference |
| ⛔ | Blocked: waits on an owner decision or an outside release or service |
| ⚠️ | Watch: a known gap or risk (a flag in the Watch column beside any badge) |

Counts: ✅ 1 · 🟢 8 · 🟡 1 · 🔵 1 · ⚪ 0 · ⛔ 2

| Status | Row | Where it stands | Watch |
|---|---|---|---|
| ✅ | HOOKS-DOC-GATE | Every shipped code block runs or carries a reason not to, and CI runs the gate on every push to `main`. | |
| 🟢 | HOOKS-KEY-CUSTODY | The custody behavior, its conformance kit and the durable key registry are on `main` with SQLite and PostgreSQL tests. | Published proof with HOOKS-RELEASE-3.2 |
| 🟢 | HOOKS-KEY-LIFECYCLE | Endpoint key issuance, reissue, adoption and retirement through custody are on `main` with SQLite and PostgreSQL tests. | Published proof with HOOKS-RELEASE-3.2 |
| 🟢 | HOOKS-INBOUND-SOURCE | Inbound sources own custody keys, provider aliases, pause and resolution, on `main` with SQLite and PostgreSQL tests. | Published proof with HOOKS-RELEASE-3.2 |
| 🟢 | HOOKS-ROW-SECURITY | Tenant-scoped resources run under database row-level security, proved on PostgreSQL. | Published proof with HOOKS-RELEASE-3.2 |
| 🟢 | HOOKS-SUBSCRIPTION-PAUSE | Subscriptions take an opt-in `paused` attribute; a paused subscription gets no new deliveries. On `main` with tests. | Published proof with HOOKS-RELEASE-3.2 |
| 🟢 | HOOKS-INBOUND-DECODER | Inbound ledgers, provider decoders and JWS signatures take the application's JSON decoder, enforced for direct and source-allowlisted providers, with a conformance check. On `main` with tests. | Published proof with HOOKS-RELEASE-3.2 |
| 🟢 | HOOKS-TRANSPORT-SAFETY | Transport resolvers fail closed, IPv6 reserved space is refused, and applications get a public-address resolver for pinning. On `main` with tests. | Published proof with HOOKS-RELEASE-3.2 |
| 🟢 | HOOKS-SPAWNED-CONTEXT | Spawned delivery work carries the tenant as data into every transaction and inherits the caller's tracer context. | Published proof with HOOKS-RELEASE-3.2 |
| 🟡 | HOOKS-RELEASE-3.2 | 3.2.0 is cut on `main` with its documentation, key guide and Livebook current and run headless against the candidate archive; the tag and the publish remain. | |
| 🔵 | HOOKS-SYNC-DECISION-RECIPE | The receiving recipe for a synchronous decision from any sender is specified; nothing is written. | ⚠️ its link waits on `request_seal` 2.0.0's signed authorization hook recipe |
| ⛔ | HOOKS-RELEASE-ORDER | The release order that runs every check on the landing commit and tags last is drafted, not adopted. | ⛔ maintainer approval of the release order |
| ⛔ | HOOKS-CI-ENGINE | CI still declares its own jobs on hosted runners. | ⛔ shared declared job definitions and their build-box matrix |
<!-- status-board:end -->

## Queue

In order. Rows that have landed stay until their release is published and verified.

| ID | Outcome | Acceptance | Waits on |
|---|---|---|---|
| HOOKS-RELEASE-3.2 | 3.2.0 is published with every new surface documented and runnable. | README, tutorials, the key guide and the Livebook cover every 3.2.0 surface and run headless against the candidate archive; the tag is on the landing commit and CI passes on it; Hex read-back matches the archive checksum; HexDocs, the Livebook from Hex and the consumer test pass; the GitHub release carries the changelog section. | nothing |
| HOOKS-SYNC-DECISION-RECIPE | A host that must answer a sender synchronously can verify any sender's signature and decide in the response. | A tutorial shows `AshHooks.Signing.verify/4` in the host's own Plug without the ingress pipeline, returns the decision in the response with no ledger row and no vendor named, states that the response is not authenticated, links `request_seal`'s signed authorization hook recipe, and runs in the documentation gate. | HOOKS-RELEASE-3.2; `request_seal` 2.0.0 for the link |
| HOOKS-RELEASE-ORDER | Every check runs on the landing commit before the tag, and the tag and release come last. | The publishing guide follows the approved order; a tag ruleset protects `v*`; the named-lock fixture proves a consumer resolves the published lock. | maintainer approval of the release order |
| HOOKS-CI-ENGINE | CI runs the shared declared jobs on the build box against upstream images pinned by digest. | PostgreSQL 16, 17 and 18 from upstream images by digest; runners selected by repository variable; `all-checks-pass` stays the verdict. | shared declared job definitions; the build-box matrix |
| HOOKS-DOC-GATE | Every code block a reader can copy is proved. | Each shipped code block carries a tested marker or a stated reason; the gate fails on a missing, orphaned, duplicated or unexecuted marker; CI runs it. | nothing |
| HOOKS-KEY-CUSTODY | Applications keep webhook keys in their own custodian. | `AshHooks.Custody` with kind assertions and tombstones; `AshHooks.Custody.Conformance` for custodians; `AshHooks.KeyRegistry` reconciles owners and destroys retired keys; SQLite and PostgreSQL tests. | HOOKS-RELEASE-3.2 |
| HOOKS-KEY-LIFECYCLE | Endpoint keys are issued, reissued, adopted and retired without the application handling key bytes. | `create_with_key/3`, `reissue_secret`, `adopt_keys` and custody-only endpoints; retirement re-checks the persisted owner; SQLite and PostgreSQL tests. | HOOKS-RELEASE-3.2 |
| HOOKS-INBOUND-SOURCE | Inbound senders are first-class records with their keys, aliases and pause state. | `AshHooks.InboundSource` creates sources, rolls, reissues and expires secrets, registers public keys, pauses and resolves; SQLite and PostgreSQL tests. | HOOKS-RELEASE-3.2 |
| HOOKS-ROW-SECURITY | Tenant isolation holds in the database, not only in the application. | The row-security tutorial; PostgreSQL tests prove each tenant-scoped resource refuses another tenant's rows. | HOOKS-RELEASE-3.2 |
| HOOKS-SUBSCRIPTION-PAUSE | A subscription can be paused and resumed through ordinary updates. | `pausable :on` injects a non-null `paused` attribute defaulting to `false`; a paused subscription creates no new delivery rows while existing deliveries continue; tests. | HOOKS-RELEASE-3.2 |
| HOOKS-INBOUND-DECODER | Inbound JSON follows the application's decoding policy. | The ledger `json_decoder` option reaches JWS protected headers, claims and payloads; `decode_payload/2` receives it; a ledger configuring it refuses any provider it can reach, declared directly or in a source allowlist, that has a host-written `decode_payload/1` and no `/2`; `AshHooks.Provider.Conformance` checks hand-written decoders use it; tests. | HOOKS-RELEASE-3.2 |
| HOOKS-TRANSPORT-SAFETY | Outbound delivery and application lookups never reach a private address. | A failing or invalid transport resolver refuses the attempt as retryable instead of falling back; IPv6 checks refuse reserved and unallocated space; `AshHooks.Ssrf.resolve_host_public/2` returns only public addresses under a deadline; tests. | HOOKS-RELEASE-3.2 |
| HOOKS-SPAWNED-CONTEXT | Work that delivery spawns runs in the caller's tenant and trace. | Job arguments carry the tenant; every phase runs in `Ash.transact/3` with the tenant, so the host binds it in its transaction hook; spawned children inherit tracer context; tests. | HOOKS-RELEASE-3.2 |
