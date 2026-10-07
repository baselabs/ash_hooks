# ADR-0009 — Bounded HTTP transport and destination pinning

- **Status:** Accepted August 22, 2026; amended October 6, 2026 for 2.0.
- **Deciders:** Maintainer, informed by independent transport and security review.

## Context

Webhook receivers control response size, framing, and timing. A large response or
one that never finishes can consume a delivery process indefinitely. Destination
validation also has to survive DNS rebinding: validating a hostname and resolving
it again when connecting can reach a different address.

OTP's `:httpc` streams only 200 and 206 responses. It can assemble a complete
non-2xx body before the package truncates it. The default adapter must enforce
bounds while reading and connect to the address that passed validation.

## Decision

`AshHooks.Http.Bounded` is the default adapter. It sends one HTTP/1.1 request per
connection and never follows redirects. Its defaults cap the combined response
headers at 32 KiB, retained body at 64 KiB, informational responses at eight, and
connection setup at five seconds. One 15-second operation deadline includes DNS,
connection setup, sending, informational responses, and body reads. The adapter
stops reading and closes the connection once the retained-body cap is reached.
Applications can override these limits explicitly.

Informational responses precede the final response; they do not become the delivery
result. A Content-Length or chunked response that closes before its declared end
returns `{:error, :truncated_body}`. Reaching the configured capture cap is distinct
from an early close. Read-to-close framing ends when the peer closes normally.

Validate endpoint URLs when written and resolve destinations again at send time.
Registration checks are offline: scheme, hostname, and literal address. Send-time
resolution queries both DNS families under a deadline, rejects an empty result and
any nonpublic returned address, then selects a validated address. The connection
uses that address; TLS SNI, certificate validation, and the `Host` header use the
original hostname. IPv6 authorities are bracketed. Embedded IPv4 forms are checked
against the IPv4 rules; 6to4 and Teredo addresses are refused.

Named HTTPS destinations use the normal certificate hostname check. A literal
HTTPS address requires the exact address in the certificate's `iPAddress` subject
alternative name. Both adapters accept an explicit `:cacerts` bundle; otherwise
they use OTP's trust store. Request methods and header bytes are validated before
serialization.

`AshHooks.Http.Httpc` remains an optional transport choice. It refuses literal-IP
HTTPS because it cannot enforce that certificate identity check. It never follows
redirects and truncates retained responses, but its non-2xx buffering remains
inside OTP. Use Bounded when collection memory and time must remain bounded.

[ADR-0012](0012-durable-delivery-ownership-and-recovery.md) defines the surrounding
delivery attempt deadline and result ownership. Transport errors, including a
certificate identity mismatch, enter the delivery retry policy; an unsafe
send-time destination is terminal.

## Consequences

- DNS validation and connection target selection share one result, closing the
  resolve-again rebinding window in the bundled adapters.
- A receiver that requires redirects needs a custom adapter and a corresponding
  destination policy.
- Literal-IP HTTPS requires a certificate containing that IP. Applications using
  a private CA supply its trust bundle through adapter options or worker `http_opts`.
- Custom adapters and explicit validation overrides replace the corresponding
  built-in boundary; hosts must assess those choices themselves.

## Historical measurements

The August 22, 2026 framing probe measured about 235 KiB peak collection against
an 8 MiB chunk declaration, compared with 16.8 MiB before the buffering correction.
A separate `:httpc` probe retained only its configured 16-byte prefix but measured
about 4.65 MiB transient allocation for a 4 MiB error response. These are dated
observations of those implementations and inputs, not capacity guarantees for 2.0.
