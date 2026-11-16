# Naming and package identity

## Decision

The package is `ash_hooks`, the repository is `baselabs/ash_hooks`, and the module
root is `AshHooks`. The description and keywords include "webhooks".
Canonical `ash_<concept>` names remain available to official Ash extensions;
keep `ash_hooks` rather than renaming it to `ash_webhooks`.
Durable names carry no version or phase suffixes. Verify ownership of the
existing Hex package before publication.

## Consequences

- Discoverability depends on the description and keywords.
- The package name covers both inbound and outbound webhooks.
