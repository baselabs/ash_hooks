# 0001: Naming and package identity

Status: Accepted August 20, 2026; amended November 16, 2026.

## Decision

The package is `ash_hooks`, the repository is `baselabs/ash_hooks`, and the module
root is `AshHooks`. The Hex description and the GitHub repository topics include
"webhooks"; Hex has no keyword field.
Canonical `ash_<concept>` names remain available to official Ash extensions;
keep `ash_hooks` rather than renaming it to `ash_webhooks`.
Durable names carry no version or phase suffixes. Verify ownership of the
existing Hex package before publication.

## Consequences

- Discoverability depends on the Hex description and the repository topics.
- The package name covers both inbound and outbound webhooks.
