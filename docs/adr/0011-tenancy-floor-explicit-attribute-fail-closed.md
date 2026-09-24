# ADR-0011 — Tenancy floor: explicit, attribute-aligned, fail-closed, not authorization

- **Status:** Accepted (2026-09-24) — implements the reviewed tenancy design
  (`.kimosabe/specs/2026-09-23-tenancy-design.md`, adversarial pass complete:
  9 findings admitted and folded in); extends ADR-0005's floors doctrine.
- **Deciders:** maintainer; independent adversarial review of the design (blocking pass)

## Context

ash_hooks 1.1.1 had no tenant concept at any layer (census-verified: zero
"tenant" occurrences across `lib/`, no public head accepting a tenant, all 18
Ash data calls tenant-less). Under multi-tenant use, six operation shapes had
global data access — most critically the subscription fanout read, which
delivers an event's payload bytes to EVERY subscription row matching its type
string, regardless of which tenant's subscriptions they are. An RLS-only
alternative carries the entire isolation burden with silent failure modes (an
RLS-invisible endpoint row is indistinguishable from a gone one and is skipped
by design).

## Decision

The package aligns with **Ash attribute multitenancy** and threads an explicit
tenant through every path. The floor, in four rules:

1. **Explicit tenant everywhere; no ambient fallback.** Every public entry
   point takes a `:tenant` (or `ctx[:tenant]` for ingest) and threads
   `tenant:` to every Ash data call it makes — all 18 sites. Ash 3.33 has no
   process-level tenant API; a package-local ambient tenant would be a second
   source of truth. Threading is unconditional and therefore inert on
   single-tenant resources (verified at both the action and data layers).
2. **Named fail-closed errors before any data access.** Each entry family
   resolves its touched-resource set first: multitenant set + no tenant →
   `{:error, :tenant_required}` (the package's named error — the bang-path
   heads would otherwise crash with Ash's TenantRequired); an inconsistent set
   (some-but-not-all declared, differing attributes, non-`:attribute`
   strategy, or `global?: true`) → `{:error, :tenancy_mismatch}`. Ash's own
   fail-closed reads remain the backstop. `global?: true` is rejected because
   it passes a same-attribute consistency check while silently permitting
   tenant-less reads — it disables every fail-closed claim this floor makes.
3. **Consumer-declared, package-verified.** Consumers declare
   `multitenancy :attribute, attribute: <same attr>, global?: false` on the
   four resources (subscription, endpoint, both ledgers); the package verifies
   the contract per call on every entry family — dispatch, the ingest family,
   the delivery runtime, both prunes, and reconciliation — and inherits Ash's
   native guarantees (fail-closed reads, tenant-scoped identity indexes and
   upsert conflict keys, tenant-scoped identity validation) rather than
   reimplementing them. A compile-time verifier covers what one module can
   know: a multitenant package resource must not mark actions
   `multitenancy :bypass` (generalized from the design's "injected actions" —
   redeclaring an injected action name dies on Ash's RequireUniqueActionNames
   first, probed; the reachable shape is the consumer's own action).
4. **Tenancy is data-plane scoping, not authorization.** `authorize?: false`
   stays on the system path (ADR-0005's posture): the dispatch call is the
   trust boundary for writes; caller-side policy remains the consumer's layer.

Supporting mechanics (the design's D5–D9): the async path serializes the row's
tenant into Oban job args (string tenants are the supported shape;
non-string tenants must round-trip `parse_attribute` over JSON — documented);
maintenance sweeps are per-tenant with `reap_all`/`prune_all` sequential sugar
(the shared repo pool is the one cross-tenant starvation surface); secret
resolution is tenant-aware on every resolving path (the worker's
`:tenant_aware_secrets` 2-arity resolver contract, the inbound 1-arity secret
fn, the provider's overridable `webhook_signing_secret/2`, and the
`verify_signature` context's `:tenant`); and `AshHooks.reconcile_pending/3`
reconciles orphan-pending rows through a real CAS flip on
`:mark_enqueue_failed` — single-winner semantics under any enqueue seam.

## Rejected alternatives

- **Package-injected tenant column with manual filters** — reimplements what
  Ash guarantees natively (indexes, upsert keys, fail-closed), doubles the
  surface, forfeits the storage-level guarantees.
- **Ambient process tenant** — unimplementable on Ash 3.33 (no API), and a
  second source of truth even where possible.
- **RLS-only** — the application path would depend on an RLS discipline the
  package cannot verify, with silent skip semantics (see Context).

## Consequences and boundaries

- Single-tenant adopters change nothing and observe nothing (byte-identical;
  the full pre-existing suite passes unchanged over tenant-less fixtures).
- Cutover with in-flight 1.1.x Oban jobs requires draining before serving
  multitenant dispatch (pre-tenancy args fail closed — correct but noisy);
  single→multi transitions on populated tables follow the ordered steps in
  the adoption checklist (backfill → regenerate indexes → enable — NULL-tenant
  rows form a shadow partition that strands effect-once).
- `:context`/`:substring` strategies are out of scope: unavailable on the
  package's sqlite test substrate; `:attribute` is the only portable strategy.
- No RLS claim: the package proves Ash-layer isolation only; adopter-side RLS
  remains defense-in-depth.
- The package makes no tenant-registry, discovery, or scheduling claims
  (`*_all` sugar composes with the adopter's tenant enumeration).
