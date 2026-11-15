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

Counts: ✅ 0 · 🟢 0 · 🟡 0 · 🔵 1 · ⚪ 0 · ⛔ 2

| Status | Row | Where it stands | Watch |
|---|---|---|---|
| 🔵 | HOOKS-SYNC-DECISION-RECIPE | The receiving recipe for a synchronous decision from any sender is specified; nothing is written. | ⚠️ its link waits on `request_seal` 2.0.0's signed authorization hook recipe |
| ⛔ | HOOKS-RELEASE-ORDER | The release order that runs every check on the landing commit and tags last is drafted, not adopted. | ⛔ maintainer approval of the release order |
| ⛔ | HOOKS-CI-ENGINE | CI still declares its own jobs on hosted runners. | ⛔ shared declared job definitions and their build-box matrix |
<!-- status-board:end -->

## Queue

In order. Rows that have landed stay until their release is published and verified; the
[changelog](../CHANGELOG.md) then records them. 3.2.0 was published and verified on November 15, 2026.

| ID | Outcome | Acceptance | Waits on |
|---|---|---|---|
| HOOKS-SYNC-DECISION-RECIPE | A host that must answer a sender synchronously can verify any sender's signature and decide in the response. | A tutorial shows `AshHooks.Signing.verify/4` in the host's own Plug without the ingress pipeline, returns the decision in the response with no ledger row and no vendor named, states that the response is not authenticated, links `request_seal`'s signed authorization hook recipe, and runs in the documentation gate. | `request_seal` 2.0.0 for the link |
| HOOKS-RELEASE-ORDER | Every check runs on the landing commit before the tag, and the tag and release come last. | The publishing guide follows the approved order; a tag ruleset protects `v*`; the named-lock fixture proves a consumer resolves the published lock. | maintainer approval of the release order |
| HOOKS-CI-ENGINE | CI runs the shared declared jobs on the build box against upstream images pinned by digest. | PostgreSQL 16, 17 and 18 from upstream images by digest; runners selected by repository variable; `all-checks-pass` stays the verdict. | shared declared job definitions; the build-box matrix |
