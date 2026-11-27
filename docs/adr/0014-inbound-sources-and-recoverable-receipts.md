# 0014: Inbound sources and recoverable receipts

Status: Accepted November 15, 2026.

## Context

Sources need durable configuration, rotation, provider selection, and pause state.
Authenticated receipts must survive changes to or deletion of that source.

## Decision

[AshHooks.InboundSource](../../lib/ash_hooks/inbound_source.ex) extends a host
resource with source-owned custody keys, typed public verification keys,
provider aliases, pause state, and lifecycle timestamps. Its unique identity
combines the declaration name and declared scope under the resource's tenant.
The source names its ledger, and each ledger declaration must point back to a
source belonging to that ledger. Source and ledger tenancy and required scope
attributes are checked at compilation and request preflight. Provider aliases
select modules only from a compile-time allowlist.

`create_source/3`, rotation, reissue, retirement scheduling, expiration, and
public-key registration are system operations. They reuse ADR-0013's issuing
and lifecycle core. Sources have no byte resolver path and refuse direct
reference input. Public verification material is validated with its pinned
algorithm kind before writes and stays outside custody. Generated symmetric
source secrets are disclosed once. An active overlap refuses another rotation;
reissue replaces only the current key, leaving the previous window unchanged.

[Ingress.resolve_source/3](../../lib/ash_hooks/ingress.ex) casts and constrains
scope using ledger attributes before looking up a source under its tenant.
Missing, nil, or invalid declared scope fails as `MalformedPayload`, including
on declarations without a source resource. An absent source row returns
`UnknownSource`. `AshHooks.Inbound.ResolvedSource` holds the selected provider
and alias, cast scope, pause state, admitted custody keys, and optional public
key. Legacy routes can reuse a same-request snapshot via `:resolved_source`.
For durable routes, ingress resolves the source itself and carries that
snapshot into verification. Declarations without a source resource retain
explicit provider configuration and their declared secret callbacks.

Pause refuses new requests before receipt creation. Authenticated receipts
retain their provider alias, payload, scope, and identity and remain recoverable
after pause, rotation, or source deletion. Claims and recovery select the
persisted alias from the source resource's allowlist, without reading the source
row. `AshHooks.Provider.DeliveryContext` supplies tenant, source, scope, alias,
and persisted delivery identity to contextual provider callbacks. Recovery
reconstructs it from the receipt, without inventing request headers.

`adopt_provider_alias/4` handles pre-cutover nonterminal receipts with no alias.
It validates the declaration and provider, claims and stamps each receipt
atomically in bounded tenant phases, and commits before running the handler.
It refuses enclosing transactions. Terminal nil-alias receipts stay unchanged;
live claims remain counted for a later bounded adoption call.

- Resolving a source independently at every HTTP and ingress step can select
  different provider or pause snapshots during one request. A reusable typed
  resolution makes the request boundary explicit.

## Consequences

Hosts migrate and authorize the source resource and manage its provider
allowlist. Pausing new traffic does not cancel accepted work. Recoverability
depends on retaining the configured alias implementation for its outstanding
receipts. Receipt adoption and lifecycle maintenance are tenant-scoped system
operations; callers must protect access to them.
