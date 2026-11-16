# Standard Webhooks and legacy dual signing

## Decision

Emit Standard Webhooks natively, using the schemes in
[the signing decision](0006-v1-and-v1a-signing-day-one.md).
A subscription's `signing_mode` selects `:legacy`, `:dual`, or `:standard`;
a nil value falls back to the outbound declaration, then to `:standard`.
Dual mode also emits the byte-identical legacy envelope with a separate legacy
secret and independent rotation lifecycle. Cutover is operator-driven:
a 2xx response cannot reveal which signature the receiver verified.
`AshHooks.Legacy.verify/5` verifies the legacy envelope.
The outbound declaration names its subscriptions and deliveries resources.

## Consequences

- Receivers can use Standard Webhooks libraries or retain legacy verification during cutover.
- Dual mode adds signature headers until the operator changes the mode.
- The package owns conformance of its native signing and verification.
