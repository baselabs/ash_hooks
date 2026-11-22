# 0031. Pinned egress for host requests

Status: accepted

## Context

Webhook delivery resolves each destination once, validates every address
against the SSRF policy, connects to a validated address and keeps the
original host for the Host header, TLS SNI and certificate verification. Hosts
also send other outbound requests, such as calls to model providers through Req
and ReqLLM, buffered and streaming. They need the same protection, no redirect
to another host, no hidden resend, and a way to tell whether request bytes may
have left, because a request that might have been processed must not be sent
again as if it had failed.

Two designs were compared from versioned library source. Pinning at the Finch
layer (Mint's `hostname:` option on an address-keyed pool) reuses connection
pools and ReqLLM's native stream path, but Finch telemetry carries the full
request and response headers to every handler, Finch replays HTTP/2
`:read_only` failures with no switch, dynamically started pools can be
recreated from defaults without the pin, and whether bytes left could only be
inferred from telemetry. Mint as the protocol engine beneath ash_hooks would
give the package two engines, adds headers that the prepared-request contract
forbids, and encodes and writes in one call.

## Decision

1. ash_hooks owns the socket. Its own HTTP/1.1 client becomes one streaming
   engine used by webhook delivery (`AshHooks.Http.Bounded`, unchanged
   behavior) and by the new public `AshHooks.Egress`. One SSRF, TLS, IP-SAN,
   certificate-pin and framing implementation serves both.
2. `AshHooks.Egress.destination/2` validates a destination when the host
   enrolls it. Each send checks the effective URL against that destination
   before any I/O, resolves once and connects to the validated address.
3. Every result says whether request bytes may have left: `sent` is `:none`
   until immediately before the first socket write and `:possible` from then
   on. Successful responses state their completion (`:complete`, `:halted`, or
   `:capture_limit` when the caller asked for a capped capture). Errors are
   `AshHooks.Egress.Error` exceptions with a closed reason set, the phase
   reached and no values.
4. No redirect is followed: a 3xx response is `:redirect_refused`. Req
   options that would follow redirects are refused before I/O.
5. ash_hooks never resends. `AshHooks.Egress.ReqAdapter` requires retries to be
   off (it accepts an installed retry function only with `max_retries: 0`) and
   refuses any second run of a request with nothing written.
6. Streams deliver status, headers and body chunks to a caller function that
   may halt; a failing callback closes the socket. Connect, idle and total
   deadlines are measured from the call's start. The socket belongs to the
   calling process.
7. `[:ash_hooks, :egress, :start | :stop]` telemetry carries a host-supplied
   destination identifier, scheme, port, address family, method, phase, sent,
   status, completion, reason, durations and byte counts. It never carries the
   host name, path, query, headers, bodies or exception terms.
8. Req is an optional dependency. The adapter compiles only when Req is loaded.
9. ash_hooks does not choose a request's destination, admit requests, bind
   credentials or record intent. A send whose process dies returns no result.
   Req-based clients reach the engine through the adapter; clients that stream
   through their own transport can call `AshHooks.Egress.stream/8` directly.

## Consequences

Each send opens one connection: no pooling and no HTTP/2. The result is exact
about whether bytes may have left, and the same TLS identity tests cover
delivery and egress. A client library whose streams bypass Req reaches the
engine only through `AshHooks.Egress.stream/8`.
