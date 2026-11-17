# 0010: Semantic versioning and support

Status: Accepted August 22, 2026; amended November 15, 2026.

## Context

Applications need stable public contracts, predictable migrations, and a
supported dependency window.

## Decision

ash_hooks follows semantic versioning over its public surface:

- The `webhooks` DSL, options and defaults; injected resource attributes,
  actions, identities, and their names and semantics.
- Public functions, event structs, resource types, behaviors and callbacks;
  telemetry event names and payloads; error classes; worker macro options;
  and the installer task.
- Provider schemes, signature and event primitives, HMAC configuration,
  pinned JWS algorithms, and request-based signature sources.
- Optional HTTP ingress and exact body exchange, provider handshake and
  response callbacks, and default HTTP response mapping. HTTP modules require
  their optional dependency.
- Custody keys, public keys, conformance and registries, canonical tenants,
  fingerprints, issuance, disposal, endpoint adoption, and reissue.
- Inbound sources and resolved snapshots, delivery context, provider conformance,
  source resolution, alias recovery, contextual callbacks, ledger `json_decoder`,
  and `decode_payload/2`.
- Outbound attempts, events, health, transport, destination policy, catalog,
  keysets, resend, replay, test sends, capture, filters, payload-version pins,
  runtime worker budgets, key lifecycle, and subscription pause declarations.
- Public additions on existing modules, including `AshHooks.Ssrf.resolve_host_public/2`,
  `AshHooks.Tenancy.from_row/1`, and the unknown-source, key-kind-mismatch,
  unknown-key, and key-unavailable error types.

Modules marked `@moduledoc false`, private helpers, exact error-message text,
DSL reference formatting, and explicitly internal interfaces are outside that
surface. The internal database phase implementation is not a public API.

1. Removal, rename, semantic reversal, or a new required argument on the covered
   surface requires a major release.
2. A deprecated path keeps working with a notice for at least two minor releases
   before removal in a major release. `UPGRADING.md` provides the migration.
3. Safety corrections use patch or minor releases, including when an application
   depends on unsafe behavior. Record them under "Fixed" in `CHANGELOG.md`.
4. The newest minor receives fixes. Supported floors are Elixir `~> 1.20`, OTP
   28 and 29, and Ash `>= 3.37.2 and < 4.0.0-0`. CI qualifies a locked consumer
   graph at the declared minimums. Raising a supported floor requires a minor release
   and an `UPGRADING.md` note.
5. Security fixes ship as patches on the supported minor. See `SECURITY.md`.

## Consequences

Adopters can pin the current major with `~> 3.0` and use `UPGRADING.md` to assess
migrations. The public contract includes generic provider APIs; applications
supply their own sender-specific implementations as described in
[the provider decision](0017-generic-providers-and-signature-primitives.md).
