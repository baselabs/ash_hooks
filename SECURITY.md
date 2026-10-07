# Security policy

AshHooks handles webhook authentication, untrusted request bodies, signing secrets,
outbound destinations, and durable delivery state. We welcome responsible reports about
any weakness in those boundaries.

## Supported versions

Security fixes are released for the newest minor release in the current major line.

| Release line | Supported |
| --- | --- |
| 2.0.x | Yes |
| Earlier releases | No |

Upgrade to a supported release before requesting a backport. Safety corrections may
tighten behavior in a patch release when the previous behavior accepted unsafe input or
misclassified an incomplete operation.

## Report a vulnerability privately

Do not open a public issue. Use GitHub's
[private vulnerability report](https://github.com/baselabs/ash_hooks/security/advisories/new).

Please include:

- the affected AshHooks version and runtime environment;
- the affected surface, such as inbound verification, outbound signing, destination
  validation, HTTP transport, delivery recovery, retention, or redaction;
- the smallest reproducible input and the observed result;
- the impact you believe is possible; and
- real service or protocol-peer evidence for transport and interoperability findings,
  when available.

Never include production secrets, credentials, or signed customer payloads. Use newly
generated credentials and synthetic payload bytes. We aim to acknowledge reports within
seven days and will coordinate validation, remediation, release timing, and credit with
the reporter.

## Security guarantees

### Inbound verification

- Signatures are checked against the exact request bytes with constant-time comparison.
  Decode the payload only after `AshHooks.Ingress` accepts it.
- Inbound DSL secret options accept resolver sources rather than literal binaries.
  Runtime secrets come from callbacks, while persisted endpoint rows contain references
  and reject known secret-material prefixes.
- Timestamped schemes enforce their replay windows before handler execution. ComplyCube
  signs only the body; its scheme has no authenticated timestamp, so retained ledger
  identities prevent repeated handling. Leases and fencing tokens prevent a stale or
  superseded owner from marking a newer claim complete.
- Inbound headers are not stored. Decoded payloads and a digest of the signed raw
  body remain in the ledger until the host applies redaction or retention policies.

### Outbound requests

- `AshHooks.Http.Bounded` is the default adapter. By default it limits the combined
  response header stream to 32 KiB, retained response bodies to 64 KiB, interim
  responses to eight, connection setup to five seconds, and the complete HTTP operation
  to 15 seconds. The operation deadline includes DNS resolution, connect, send, interim
  responses, and body reads. Once the body cap is reached, the adapter returns the
  retained prefix and closes the connection without draining the remaining response.
- Redirects are never followed. A redirect is returned to the delivery state machine and
  classified as refused.
- Destination validation runs when an endpoint is written and again when it is sent.
  Metadata hosts and non-global IPv4 and IPv6 ranges are rejected. DNS validation is
  fail-closed: every returned address must be public, and the connection is pinned to a
  validated address while TLS and the `Host` header continue to use the original host.
- TLS uses the OTP trust store unless the host supplies a CA bundle. Hostnames use the
  normal certificate hostname check. Literal HTTPS addresses must match an `iPAddress`
  subject alternative name.
- HTTP methods come from a finite supported set. Header names must be valid HTTP tokens;
  header values and event identifiers must be valid UTF-8 and cannot contain control
  bytes. Validation happens before serialization in both bundled adapters.
- `AshHooks.Http.Httpc` remains available, but OTP may assemble a non-2xx body before the
  package can truncate it. It also refuses literal-IP HTTPS because it cannot enforce the
  IP subject-alternative-name check. Use the bounded adapter when these guarantees matter.

### Delivery state and stored data

- Each delivery attempt has a finite deadline covering endpoint reads, secret
  resolution, signing, transport, response handling, and the result write. Attempt and
  enqueue tokens, finite leases, durable source/route ownership, and endpoint snapshots
  prevent stale workers from committing a result or disabling a replacement endpoint.
- Response bodies are not stored by default. Explicit diagnostic capture runs through a
  bounded redaction pipeline before persistence.
- Telemetry contains identifiers, counts, states, and classified reasons. Secret
  material is not emitted.
- The package performs internal state transitions with authorization disabled. Consumer
  read and write surfaces remain governed by the host application's Ash policies.

## Reportable issues

Examples include:

- accepting an invalid, forged, replayed, or stale inbound delivery;
- exposing secret material through storage, logs, errors, telemetry, or response capture;
- reaching a private, link-local, loopback, reserved, or metadata destination without an
  explicit validation override;
- following an outbound redirect or accepting the wrong TLS identity;
- bypassing header, body, interim-response, or operation-time bounds;
- allowing a stale delivery owner to commit, resend, or disable an endpoint;
- crossing tenant or declared resource boundaries; and
- reprocessing a terminal row or allowing a superseded row to reach a handler.

Host application policies, migrations, secret-manager controls, queue scheduling, and
receiver-side deduplication are outside the package's enforcement boundary. Custom HTTP
adapters and explicit destination-validation or bound overrides replace the corresponding
built-in guarantee and should be assessed as part of the host application.

The public support and compatibility policy is recorded in
[ADR-0010](https://github.com/baselabs/ash_hooks/blob/main/docs/adr/0010-semver-and-support-policy.md).
