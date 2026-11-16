# Architecture decision records

Each record states one decision that shapes ash_hooks: its context, the decision and its
consequences. The code follows these records; a change that contradicts one changes the
record in the same commit.

To propose a decision, add the next number with the same three sections and a line in the
table below. Supersede a record by editing it and saying what replaced the old decision.
Records are repository documentation and are not part of the Hex package.

| Record | Decision |
|---|---|
| [0001 - Naming and package identity](0001-naming-and-package-identity.md) | Package, repository and module names. |
| [0002 - Standard Webhooks and legacy dual signing](0002-standard-webhooks-canon-with-legacy-dual-sign.md) | Standard Webhooks as the signing canon; legacy dual signing. |
| [0003 - Fenced unique-ingest ledger](0003-dedup-is-a-fenced-unique-ingest-ledger.md) | Inbound deduplication as a fenced unique-ingest ledger. |
| [0004 - Optional Oban and host-injected workers](0004-optional-oban-host-injected-worker.md) | Oban is optional; the host injects the worker. |
| [0005 - Security defaults and application boundaries](0005-security-floors-shipped-in-package.md) | Security defaults the package ships, and what the application owns. |
| [0006 - SW v1 and v1a (ed25519) signing, both schemes](0006-v1-and-v1a-signing-day-one.md) | Symmetric v1 and Ed25519 v1a signing. |
| [0007 - Synchronous inbound processing and ledger keys](0007-verified-substrate-and-as-built-inbound-mechanisms.md) | Synchronous inbound processing and ledger keys. |
| [0008 - The delivery row owns retry policy](0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md) | The delivery row owns retry policy; Oban only triggers. |
| [0009 - Bounded HTTP transport and destination pinning](0009-bounded-http-default-and-ssrf-pinning.md) | Bounded HTTP transport and destination pinning against SSRF. |
| [0010 - Semantic versioning and support](0010-semver-and-support-policy.md) | Semantic versioning and the supported versions. |
| [0011 - Explicit attribute tenancy and transaction binding](0011-tenancy-floor-explicit-attribute-fail-closed.md) | Explicit attribute tenancy that fails closed. |
| [0012 - Durable delivery ownership and recovery](0012-durable-delivery-ownership-and-recovery.md) | Durable outbound delivery ownership and recovery. |
| [0013 - Key custody, issuance, and durable disposal](0013-key-custody-issuance-and-durable-disposal.md) | Key custody, issuance and durable disposal. |
| [0014 - Inbound sources and recoverable receipts](0014-inbound-sources-and-recoverable-receipts.md) | Inbound sources and receipts that survive source changes. |
| [0015 - Tenant transactions and spawned work](0015-tenant-transactions-and-spawned-work.md) | Tenant transactions and work spawned from them. |
| [0016 - Inbound JSON decoding policy](0016-inbound-json-decoding-policy.md) | Inbound JSON decoding policy. |
| [0017 - Generic providers and signature primitives](0017-generic-providers-and-signature-primitives.md) | Generic providers and signature primitives. |
| [0018 - Optional HTTP ingress and exact body bytes](0018-optional-http-ingress-and-exact-body-bytes.md) | Optional HTTP ingress and exact body bytes. |
| [0019 - Delivery audit and observation](0019-delivery-audit-and-observation.md) | Delivery audit history and observation. |
| [0020 - Resend, replay, and endpoint health](0020-resend-replay-and-endpoint-health.md) | Resend, replay and endpoint health. |
| [0021 - Host trust boundaries and subscription selection](0021-host-trust-boundaries-and-subscription-selection.md) | Host trust boundaries and subscription selection. |
| [0022 - Oban engine row security](0022-oban-engine-row-security.md) | Separate tenant-bound insertion from queue execution under forced row security. |
| [0023 - Installer mutation scope](0023-installer-mutation-scope.md) | What the installer may edit in a host application. |
| [0024 - SQLite contention retry](0024-sqlite-contention-retry.md) | Bounded retry of SQLite write contention. |
| [0025 - Inbound handler results](0025-inbound-handler-results.md) | How ingress records every handler result. |
| [0026 - Retention action injection](0026-retention-action-injection.md) | Whether the package may delete delivery rows. |
| [0027 - Observation read failures](0027-observation-read-failures.md) | Observation read failures are reported, never counted as zero. |
