# ADR-0010 — Semver and support policy (the 1.0.0 contract)

- **Status:** Accepted (2026-08-22) — effective with the 1.0.0 release
- **Deciders:** maintainer

## Context

1.0.0 freezes a public API. Adopters (#12, #13 in flight) are building against it, and
nothing in the repo yet states what stability the version number promises, which
surfaces are covered, or how deprecation works. Semver applies cleanly only when the
covered surface is named.

## Decision

From 1.0.0, ash_hooks follows **semantic versioning** over this covered surface:

- **Covered:** the `webhooks` DSL (sections, options, defaults), the public functions of
  `AshHooks` / `AshHooks.Ingress` / `AshHooks.Delivery` / `AshHooks.Dispatcher` /
  `AshHooks.Signing` / `AshHooks.Legacy` / `AshHooks.Ssrf` / `AshHooks.Provider` (the
  behaviour + its callbacks), the injected resource attributes/actions/identities and
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
3. **Behavior corrections that close a safety hole are patch/minor, not major** — a
   defect whose current behavior is unsafe (accepting what must be rejected, classifying
   truncated bodies as success) is fixed forward and CHANGELOG'd under "Fixed", even
   where a consumer might have depended on the defect.
4. **Support matrix:** the newest minor release of ash_hooks receives fixes; the
   supported floors are Elixir ~> 1.17, OTP 27+, Ash ~> 3.0 — each floor is
   CI-tested (the `floor` leg resolves dependencies at the declared
   minimums; the original 1.15 claim was disproven by that leg: modern ash
   requires the `Duration` struct, added in Elixir 1.17). When a floor must
   rise, it rises in a MINOR release with an UPGRADING.md note (a supported-floor bump
   is explicitly not treated as major — the ecosystem convention for library floors).
5. **Security fixes** land on the supported minor and are released as patches
   (see SECURITY.md).

## Consequences

- Adopters can pin `~> 1.0` and reason about upgrades from the version number alone.
- The covered/not-covered line gives the internals room to evolve without major churn.
- The policy itself changes only via this ADR's amendment — never silently in a
  changelog.
