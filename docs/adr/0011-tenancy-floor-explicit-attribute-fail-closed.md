# 0011 - Explicit attribute tenancy and transaction binding

## Decision

The package uses Ash attribute multitenancy and threads the explicit tenant
through every entry point and data operation. Single-tenant resources need no
tenant. There is no ambient tenant fallback.

Each entry family preflights the resources it touches before data access.
A multitenant set without a tenant returns `:tenant_required`. Mixed tenancy,
different attributes, a non-attribute strategy, `global?: true`, or inconsistent
tenant conversion returns `:tenancy_mismatch`. Ash fail-closed reads and native
tenant-scoped identities and upserts remain the storage backstop.

Hosts declare compatible attribute tenancy with `global?: false`. Compile-time
verification rejects bypass actions on multitenant package resources, including
host-defined actions. Runtime preflight checks cross-resource consistency.
Tenancy scopes data; hosts own authorization. System operations use
`authorize?: false` and require an application trust boundary.

Tenant-scoped resources include endpoints, subscriptions, outbound deliveries,
attempt history, event logs, inbound ledgers, inbound sources, and key registries.
Complete primary keys, declaration/route ownership, and independent enqueue
leases govern recovery as defined in
[delivery ownership](0012-durable-delivery-ownership-and-recovery.md).

Worker jobs serialize the row's tenant in `args["tenant"]` and validate it on
execution. Custom tenant conversion must round-trip through queue JSON and its
inverse. Secret resolution receives the tenant. Maintenance runs per tenant;
`*_all` helpers compose with host enumeration and do not discover tenants.

Every database phase uses a tenant-bearing `Ash.transact` when supported and
reads through the write repository on supported SQL layers. Tenant conversion
must agree across all resources in that phase. Nontransactional layers supply
no row-security transaction binding. See
[transaction ownership](0015-tenant-transactions-and-spawned-work.md).

## Consequences and boundaries

- Single-tenant resources retain their ordinary behavior.
- Drain tenant-less queued work before multitenant dispatch. For populated tables,
  backfill tenants and rebuild indexes before enabling tenancy, following the
  [adoption checklist](../../documentation/tutorials/tenancy-adoption-checklist.md).
  Null-tenant rows can form a separate partition and permit repeated processing.
- Only attribute tenancy is supported; context and substring strategies are refused.
- The [row-security guide](../../documentation/tutorials/row-security.md) defines
  the repository transaction hook that binds the outermost transaction's tenant
  to transaction-local policy state. Joined phases do not invoke it again.
- Hosts own table and queue policies, database roles, and per-tenant scheduling.
  Row security supplements required attribute tenancy and application authorization.
