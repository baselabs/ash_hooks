# 0026: Retention action injection

Status: Accepted November 16, 2026.

Amended: November 27, 2026.

## Context

Hosts own retention (ADR 0005). `Delivery.prune/2` removes old delivery rows,
together with their attempt history, in one transaction (ADR 0019). Some hosts
must keep delivery rows append-only, for example to meet an audit or legal hold
requirement.

## Decision

`outbound_delivery` has a `prune_action` option, and the default is `:destroy`:

- **`:destroy`** generates a `:prune` destroy action. `Delivery.prune/2` uses it.
- **`:none`** generates no prune action. `Delivery.prune/2` then refuses the
  resource with an error that names the option. The package adds no other destroy
  action. Any destroy action the host declares is left as it is, under the host's
  own policies.

`:none` does not make a resource immutable. Immutability belongs to the host's
policies and database grants. Pruning removes rows, so a delivery identity that
has been pruned can be created again.

## Consequences

A host chooses at compile time whether the package may delete delivery rows. A
host that chooses `:none` keeps deduplication identities as long as it keeps the
rows, and owns any archiving.

## Protected inbound receipts

Inbound ledgers can enable `retain_replay_identities :on`. The generated
inbound `:prune` action and the prune driver both exclude protected receipts
at every cutoff. Hosts restrict other actions and database roles so cleanup
cannot delete those rows or rewrite their identity.

`Ingress.compact_replay_receipts/2` clears the payload and handler metadata
for a bounded batch of protected terminal receipts. The action filters on
terminal state at the write. Cleanup uses first insertion time because a
timestamp-free signature carries no send-age evidence. Recoverable receipts
keep their first handler input. Compaction leaves the unique-ingest fence
and its terminal outcome intact.

An active authority's replay identities have no TTL. After admission is
irreversibly closed, outstanding work is drained, and the namespace is
retired from reuse, a host may release identities through an audited
maintenance role. Package prune provides no retirement override.
