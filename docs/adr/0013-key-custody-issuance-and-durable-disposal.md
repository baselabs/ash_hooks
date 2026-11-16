# 0013 - Key custody, issuance, and durable disposal

## Context

Keys must stay opaque while owner writes and external storage can fail separately.
Every stored key needs a durable disposal obligation, including failed creation.

## Decision

[AshHooks.Custody](../../lib/ash_hooks/custody.ex) is the public behavior for
storing decoded material, signing, verification, public-key disclosure,
fingerprints, and destruction. `AshHooks.Custody.Key` carries opaque metadata.
Every operation asserts the stored kind before computing. Standard symmetric,
standard asymmetric, sender-only HMAC, and legacy HMAC kinds have distinct
material and operation contracts; sender-only keys cannot sign outbound data.
Secret material never returns from custody after storage.

References are globally unique, occupy one owner slot, and bind atomically to a
canonical tenant at first store or destroy. Cross-tenant operations cannot reveal
or use a key. Destroy is idempotent and leaves a permanent tombstone, even for a
never-stored reference, so delayed storage cannot resurrect it. Store/destroy
ordering must be linearizable. Built-in tenant canonicalization follows resource
conversion, parsing, and type constraints; custom types require the host's
equality-preserving `custody_tenant_key` contract.

`AshHooks.Custody.Conformance` supplies consumer tests for bounds, kind
assertions, tenant isolation, signatures, fingerprints, idempotence, and
store/destroy races against a real store. It requires the test framework only
in consumer tests and does not establish a backend's timing properties.
Display fingerprints are domain-separated for standard keys, agree for both
halves of an asymmetric pair, and are unavailable for sender and legacy kinds.
They do not protect weak secrets against guessing.

[AshHooks.KeyRegistry](../../lib/ash_hooks/key_registry.ex) is a host-resource
extension on a supported transactional SQL layer, with matching owner tenancy,
the same data layer, and the same write repository and connection. Issuance
commits independently before custody storage, which runs outside transactions.
Owner attachment and replacement retirement then share one tenant transaction.
Attachment checks the persisted owner's intended references and kind markers;
it refuses an expired issue or mismatched owner. Failed attempts retire their
own issues, while timed-out issues survive crashes for sweeping. The default
issue timeout is 900 seconds and must exceed the custody store timeout.

Hosts schedule registry sweeps per tenant. Sweeps reconcile owners, including
deletion paths, using the reserved owner read action; the resource's base filter
still defines existence. Retired references are destroyed outside transactions
using the recorded canonical tenant. Unavailability retries with capped
exponential backoff; final failures park with classified telemetry for inspection
and `rearm/3`. Generation and retry-attempt fences reject stale destruction
results. Pruning destroyed registry audit rows never removes custody tombstones.

[Endpoint](../../lib/ash_hooks/endpoint.ex) exposes `create_with_key/3`,
`roll_secret/2`, `reissue_secret/2`, and `adopt_keys/2`. Issuing operations refuse
an enclosing transaction. Generation discloses a symmetric secret or asymmetric
public half once, without storing that disclosure on the endpoint. Reissue
replaces a lost current disclosure without extending the previous key's window.
Adoption resolves occupied byte slots and preserves lifecycle timestamps; existing
custody slots stay intact. Legacy adoption requires its lifecycle option.

Kind markers travel with their adjacent references during rotation. Standard
and opt-in legacy slots share overlap caps, retirement scheduling, deadline
enforcement at signing, and reference-fenced first-use timestamps. Active overlaps
refuse another roll. Undated previous keys keep signing, are skipped by sweeps,
and require scheduling or explicit expiration before another roll. With lifecycle
tracking off, previous byte references sign until removed.

Mixed byte and custody slots support explicit adoption. Without a byte resolver,
custody endpoints require issuing APIs and refuse caller-chosen references.
`key_material: :custody_only` rejects endpoint and worker byte resolvers,
inbound byte-secret sources, and provider secret callbacks at compile time;
direct byte-signing primitives remain supported. Custody callback faults are
classified outages, never exposed backend terms or forged-signature verdicts.

## Consequences

Hosts own a conforming custodian, owner and registry migrations, authorization,
and per-tenant lifecycle and disposal schedules. Issuance, storage, attachment,
and destruction have explicit recovery states rather than implicit cleanup.
Disclosures must be delivered securely when returned; lost generated disclosures
are recovered by replacing the current key, not reading stored secret material.

Inbound source lifecycle uses the same issuance and disposal core; ADR-0014 owns
its source identity, provider selection, and receipt recovery rules.
