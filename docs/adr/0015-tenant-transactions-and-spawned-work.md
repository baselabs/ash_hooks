# 0015 — Tenant transactions and spawned work

- **Status:** Accepted November 15, 2026
- **Deciders:** maintainer

## Context

Attribute filters alone cannot supply a database connection's row-security
binding. Reads routed to a separate repository and work started in another
process can lose the transaction that supplied that binding. Holding a host
transaction open across delivery also hides uncommitted rows from the monitored
driver and can block it.

## Decision

Every package database phase goes through the internal
[phase implementation](../../lib/ash_hooks/phase.ex). For transaction-capable
resources it opens `Ash.transact` with an explicit tenant key. It converts the
caller tenant with `Ash.ToTenant` for every resource in the phase and refuses
disagreement with `:tenancy_mismatch` before opening a transaction. Reads on the
supported transactional SQL layers use the write repository through data-layer
context, including when ordinary reads would route elsewhere. Nontransactional
layers retain their prior behavior and supply no row-security transaction
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

## Alternatives

- Inline transactional delivery makes external effects occur before commit and
  conflicts with the monitored child's access to uncommitted state. Commit the
  delivery, enqueue durably, and execute after commit instead.
- Ambient process-context transfer of the tenant creates a second source of
  truth and cannot establish a new connection's transaction binding. Tenant data
  in arguments and transaction reasons supplies the binding explicitly.
- Binding a session setting outside a transaction can leak across pooled
  connections. Transaction-local state clears at commit or rollback.
- Read-repository routing inside a phase can miss both the tenant setting and
  uncommitted writes. The write repository is the phase's authoritative view.

## Consequences

Row security is host-bound defense in depth alongside required attribute
tenancy and application authorization. Long-running external work does not
occupy package transactions. Hosts must bind enclosing transactions correctly,
configure the queue repository, preserve tenant serialization, and schedule
tenant-specific maintenance. Unsupported data layers do not gain row-security
guarantees from this decision.
