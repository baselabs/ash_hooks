# ADR-0001 — Naming and package identity

- **Status:** Accepted (2026-08-20)
- **Deciders:** operator (ratified), kimosabe-scout design pass

## Context

The baselabs `ash_*` family deliberately avoids canonical `ash_<concept>` names so official
Ash-team extensions stay free to claim them. A package name must also be free on hex.pm
(first-publish-first-owned).

## Decision

The package is **`ash_hooks`** (hex: `baselabs/ash_hooks`, module root `AshHooks`), carrying
"webhooks" in description/keywords. Never rename to `ash_webhooks`. No version or phase
suffixes in durable names. Availability verified 2026-08-20 (`ash_hooks`, `ash_webhooks`,
`ash_webhook` all free on hex); re-verify immediately before `mix hex.publish`.

## Consequences

- Canonical names remain available to the Ash team; discoverability rides keywords.
- The name undersells scope slightly (inbound + outbound webhooks) — accepted.
