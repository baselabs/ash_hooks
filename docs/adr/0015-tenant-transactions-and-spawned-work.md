# 0015: Tenant transactions and spawned work

Status: Accepted November 15, 2026.

## Context

Row-security binding belongs to a database transaction and connection.
Reads and spawned delivery work must retain tenant identity without holding external work inside it.

## Decision

Every package database phase goes through the internal
[phase implementation](../../lib/ash_hooks/phase.ex). For transaction-capable
resources it opens `Ash.transact` with an explicit tenant key. It converts the
caller tenant with `Ash.ToTenant` for every resource in the phase and refuses
disagreement with `:tenancy_mismatch` before opening a transaction. Reads on the
supported transactional SQL layers use the write repository through data-layer
context, including when ordinary reads would route elsewhere. Nontransactional
layers retain nontransactional behavior and supply no row-security transaction
binding.

The host repository's transaction-begin hook binds the reason's tenant to
transaction-local row-security state. The outermost transaction must carry the
same tenant: joined package phases do not invoke the hook again. Raw repository
transactions do not invoke the resource framework's transaction hook by
themselves. Hosts own table policies, database-role privileges, and job-table
policies. Compatible attribute tenancy remains required as recorded in ADR-0011.
The [row-security guide](../../documentation/tutorials/row-security.md) defines
the binding contract.

HTTP calls, handlers, custody operations, and retry sleeps run outside the
package's database phases. Owner attachment and retirement retain their required
shared transaction as recorded in ADR-0013. Maintenance and registry sweeps run
per tenant; the package does not discover tenants or establish a global binding.

[Delivery.run/2](../../lib/ash_hooks/delivery.ex) and `test_send/2` refuse an
enclosing delivery-resource transaction with `:inside_transaction` before
spawning or database access. Their monitored delivery and finalization children
carry the tenant as explicit data. Only tracer context is inherited through
`Ash.ProcessHelpers.get_context_for_transfer` and `transfer_context`; neither
ambient tenant state nor the caller's database transaction is transferred.
The attempt deadline and finalization allowance remain owned by the driver.

[Generated worker jobs](../../lib/ash_hooks/worker.ex) serialize the stored
row's tenant in `args["tenant"]` for multitenant work and validate it on execution.
Stored tenant attributes are converted back through `tenant_from_attribute`
before reuse. Tenant values must survive job JSON encoding; strings and integers
do, while atoms arrive as strings. Custom parsing must round-trip through its
inverse. Queue insertion occurs in a tenant phase after delivery persistence;
the queue instance must share the ledger repository for that binding. An inline
enqueue callback invoking the driver inside a host transaction is refused and
reported as enqueue failure, leaving the pending row recoverable.

A row-security setting belongs to one connection and transaction. A child process or a
separately routed read does not inherit that transaction's binding; a monitored delivery
child cannot rely on the parent's uncommitted rows and may wait on its locks.

Inline network delivery can expose external effects before a host transaction commits
and cannot depend on the monitored child seeing uncommitted state. Persist the delivery
and enqueue durably; execute the network driver after commit. Compatible job insertion
may join the host transaction; invoking the driver inside that transaction is refused.

- Ambient process-context transfer of the tenant creates a second source of
  truth and cannot establish a new connection's transaction binding. Tenant data
  in arguments and transaction reasons supplies the binding explicitly.

## Consequences

Row security is host-bound defense in depth alongside required attribute
tenancy and application authorization. Long-running external work does not
occupy package transactions. Hosts must bind enclosing transactions correctly,
configure the queue repository, preserve tenant serialization, and schedule
tenant-specific maintenance. Unsupported data layers do not gain row-security
guarantees from this decision.
