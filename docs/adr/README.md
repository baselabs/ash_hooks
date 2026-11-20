# Architecture decision records

Each record states one decision that shapes ash_hooks: its context, the decision and its
consequences. The code follows these records; a change that contradicts one changes the
record in the same commit.

To propose a decision, add the next numbered record titled `# NNNN: Title` with a
`Status:` line, the same three sections, and a line in the table below. Supersede a
record by updating its status and saying what replaced the old decision.
Records are repository documentation and are not part of the Hex package.

| Record | Status | Decision |
|---|---|---|
| [0001: Naming and package identity](0001-naming-and-package-identity.md) | Amended | Package, repository and module names. |
| [0002: Standard Webhooks and legacy dual signing](0002-standard-webhooks-canon-with-legacy-dual-sign.md) | Amended | Standard Webhooks as the signing canon; legacy dual signing. |
| [0003: Fenced unique-ingest ledger](0003-dedup-is-a-fenced-unique-ingest-ledger.md) | Amended | Inbound deduplication as a fenced unique-ingest ledger. |
| [0004: Optional Oban and host-injected workers](0004-optional-oban-host-injected-worker.md) | Amended | Oban is optional; the host injects the worker. |
| [0005: Security defaults and application boundaries](0005-security-floors-shipped-in-package.md) | Amended | Security defaults the package ships, and what the application owns. |
| [0006: SW v1 and v1a (ed25519) signing, both schemes](0006-v1-and-v1a-signing-day-one.md) | Amended | Symmetric v1 and Ed25519 v1a signing. |
| [0007: Synchronous inbound processing and ledger keys](0007-verified-substrate-and-as-built-inbound-mechanisms.md) | Amended | Synchronous inbound processing and ledger keys. |
| [0008: The delivery row owns retry policy](0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md) | Amended | The delivery row owns retry policy; Oban only triggers. |
| [0009: Bounded HTTP transport and destination pinning](0009-bounded-http-default-and-ssrf-pinning.md) | Amended | Bounded HTTP transport and destination pinning against SSRF. |
| [0010: Semantic versioning and support](0010-semver-and-support-policy.md) | Amended | Semantic versioning and the supported versions. |
| [0011: Explicit attribute tenancy and transaction binding](0011-tenancy-floor-explicit-attribute-fail-closed.md) | Amended | Explicit attribute tenancy that fails closed. |
| [0012: Durable delivery ownership and recovery](0012-durable-delivery-ownership-and-recovery.md) | Amended | Durable outbound delivery ownership and recovery. |
| [0013: Key custody, issuance, and durable disposal](0013-key-custody-issuance-and-durable-disposal.md) | Accepted | Key custody, issuance and durable disposal. |
| [0014: Inbound sources and recoverable receipts](0014-inbound-sources-and-recoverable-receipts.md) | Accepted | Inbound sources and receipts that survive source changes. |
| [0015: Tenant transactions and spawned work](0015-tenant-transactions-and-spawned-work.md) | Accepted | Tenant transactions and work spawned from them. |
| [0016: Inbound JSON decoding policy](0016-inbound-json-decoding-policy.md) | Accepted | Inbound JSON decoding policy. |
| [0017: Generic providers and signature primitives](0017-generic-providers-and-signature-primitives.md) | Amended | Generic providers and signature primitives. |
| [0018: Optional HTTP ingress and exact body bytes](0018-optional-http-ingress-and-exact-body-bytes.md) | Accepted | Optional HTTP ingress and exact body bytes. |
| [0019: Delivery audit and observation](0019-delivery-audit-and-observation.md) | Amended | Delivery audit history and observation. |
| [0020: Resend, replay, and endpoint health](0020-resend-replay-and-endpoint-health.md) | Accepted | Resend, replay and endpoint health. |
| [0021: Host trust boundaries and subscription selection](0021-host-trust-boundaries-and-subscription-selection.md) | Amended | Host trust boundaries and subscription selection. |
| [0022: Oban engine row security](0022-oban-engine-row-security.md) | Accepted | Separate tenant-bound insertion from queue execution under forced row security. |
| [0023: Installer mutation scope](0023-installer-mutation-scope.md) | Accepted | What the installer may edit in a host application. |
| [0024: SQLite contention retry](0024-sqlite-contention-retry.md) | Accepted | Bounded retry of SQLite write contention. |
| [0025: Inbound handler results](0025-inbound-handler-results.md) | Accepted | How ingress records every handler result. |
| [0026: Retention action injection](0026-retention-action-injection.md) | Accepted | Whether the package may delete delivery rows. |
| [0027: Observation read failures](0027-observation-read-failures.md) | Accepted | Observation read failures are reported, never counted as zero. |
| [0028: Host extension seams](0028-host-extension-seams.md) | Accepted | Verified facts, host signers, exact prepared requests and signing provenance. |
| [0029: Transactional publication and query matching](0029-transactional-publish-and-query-matching.md) | Accepted | A dedicated outbox and query-side selection with an Elixir guard. |
| [0030: Visible worker outcomes](0030-visible-worker-outcomes.md) | Accepted | Cancel absent, failed and invalid work visibly; preserve row-owned recovery. |
