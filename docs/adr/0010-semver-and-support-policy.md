# 0010 — Semver and support policy (the 1.0.0 contract)

- **Status:** Accepted (2026-08-22); effective with the 1.0.0 release; support floors amended 2026-09-16 (owner decision, released as 1.1.0): the Elixir floor rose from ~> 1.17 to ~> 1.20 and the OTP floor from 27+ to 28+ (CI tests 28 and 29; 1.17 to 1.19 support was retired, not merely discouraged). The minor-release treatment of floor bumps below is unchanged; 1.1.0 is its first exercise; amended November 15, 2026
- **Deciders:** maintainer

## Context

Applications need a clear contract for dependency upgrades: which interfaces stay
stable, which changes require migration, and how long deprecated behavior remains
available. Semantic versioning needs an explicit public surface to make that
promise useful.

## Decision

From 1.0.0, ash_hooks follows **semantic versioning** over this covered surface:

- **Covered:** the `webhooks` DSL (sections, options, defaults), the public functions of
  `AshHooks` / `AshHooks.Ingress` / `AshHooks.Delivery` / `AshHooks.Dispatcher` /
  `AshHooks.Signing` / `AshHooks.Legacy` / `AshHooks.Ssrf` / `AshHooks.Provider` (the
  behavior + its callbacks), `AshHooks.OutboundBinding` and the public ingress
  identity-adoption operations (added in 2.0), the injected resource attributes/actions/identities and
  their names and semantics, telemetry event names + payload shapes, error classes, the
  `use AshHooks.Worker` macro options, and the installer task.
- **Not covered:** `@moduledoc false` modules, function arity/shape of private helpers,
  the exact text of error messages, DSL cheat-sheet formatting, and anything the docs
  label internal.

Rules:

1. **Breaking changes bump major.** Removal, rename, semantic reversal, or a new
   required argument on covered surface.
2. **Deprecations run two minors minimum:** a deprecated path keeps working (with a
   compile-time or runtime deprecation notice) for at least two minor releases before
   any major removes it. UPGRADING.md carries every migration.
3. **Behavior corrections that close a safety hole are patch/minor, not major**; a
   defect whose current behavior is unsafe (accepting what must be rejected, classifying
   truncated bodies as success) is fixed forward and CHANGELOG'd under "Fixed", even
   where a consumer might have depended on the defect.
4. **Support matrix:** the newest minor release of ash_hooks receives fixes; the
   supported floors are Elixir ~> 1.20, OTP 28+, Ash >= 3.37.2 and < 4.0 *(Ash floor
   amended November 12, 2026 so that no admitted Ash release carries a published
   advisory: EEF-CVE-2026-101028, -114214 and -96581, fixed in 3.34.6, 3.37.1 and
   3.37.2; amended October 6, 2026 for the tenant inverse API and CVE-2026-94201;
   this release also requires the 2.0 durable-schema migration. Earlier support floors amended
   2026-09-16, released as 1.1.0: previously Elixir ~> 1.17, OTP 27+. History: the
   original 1.15 claim was disproven by the floor leg; modern ash requires the
   `Duration` struct, added in Elixir 1.17)*; each floor is
   CI-tested (the `floor` leg resolves dependencies at the declared
   minimums). When a floor must rise, it rises in a MINOR release with an
   UPGRADING.md note (a supported-floor bump is explicitly not treated as
   major; the ecosystem convention for library floors).
5. **Security fixes** land on the supported minor and are released as patches
   (see SECURITY.md).

## Consequences

- Adopters can pin the current major (`~> 2.0`) and assess upgrades through the
  version number and the ordered migration in UPGRADING.md.
- The covered/not-covered line gives the internals room to evolve without major churn.
- The policy itself changes only via this ADR's amendment; never silently in a
  changelog.

## Amendment (November 15, 2026)

The package version in [mix.exs](../../mix.exs) is 3.2.0. The historical
`~> 2.0` adoption guidance is replaced by the current-major constraint `~> 3.0`.
Migration guidance accompanies major changes; version 3.0.0 removed packaged
vendor verifiers and provider-name inference, as recorded in ADR-0017.

The original public-surface list is not exhaustive for the current release.
The [release history](../../CHANGELOG.md) and public module documentation add:

- `AshHooks.Provider.Scheme`, `AshHooks.Provider.Signature`,
  `AshHooks.Provider.Event`, and the generic `AshHooks.Provider.Hmac`
  configuration and signature APIs, including pinned JWS algorithms and
  request-based signature sources.
- `AshHooks.Plug` and `AshHooks.BodyReader`'s public exact-byte exchange,
  provider handshake and response callbacks, and default HTTP response mapping.
  The optional HTTP modules exist only when their dependency is installed.
- `AshHooks.Custody`, `AshHooks.Custody.Key`, `AshHooks.Custody.PublicKey`,
  `AshHooks.Custody.Conformance`, and `AshHooks.KeyRegistry`, including canonical
  tenant identities, display fingerprints, issuance, disposal, and endpoint
  adoption and reissue operations.
- `AshHooks.InboundSource`, `AshHooks.Inbound.ResolvedSource`,
  `AshHooks.Provider.DeliveryContext`, and `AshHooks.Provider.Conformance`,
  including source resolution, alias recovery, contextual provider callbacks,
  ledger `json_decoder`, and `decode_payload/2`.
- The post-2.0 operational surface: `AshHooks.OutboundAttempt`,
  `AshHooks.OutboundEvent`, `AshHooks.EndpointHealth`, `AshHooks.Transport`,
  `AshHooks.DestinationPolicy`, `AshHooks.Catalog`, and `AshHooks.Keyset`;
  resend, replay, test sends, optional capture, filters, payload-version pins,
  runtime worker budgets, key lifecycle, and subscription pause declarations.
- Public additions on existing modules, including
  `AshHooks.Ssrf.resolve_host_public/2`, `AshHooks.Tenancy.from_row/1`,
  `AshHooks.Errors.Invalid.UnknownSource`,
  `AshHooks.Errors.Invalid.KeyKindMismatch`, `AshHooks.Errors.Invalid.UnknownKey`,
  and `AshHooks.Errors.Unknown.KeyUnavailable`. Public event structs and resource
  types remain subject to their documented contracts.

This inventory extends the existing rule for public functions, DSL declarations,
injected resource contracts, errors, and telemetry. It does not promote modules
marked `@moduledoc false`, such as the database phase implementation, into public
API. The supported dependency floors and minor-release treatment of floor
increases remain as stated above.
