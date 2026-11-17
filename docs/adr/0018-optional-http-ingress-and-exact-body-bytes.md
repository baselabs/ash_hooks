# 0018: Optional HTTP ingress and exact body bytes

Status: Accepted November 15, 2026.

## Context

HTTP ingress needs exact bytes, source resolution, challenges, and acknowledgments.
The core pipeline must also work without an HTTP framework.

## Decision

[AshHooks.Plug](../../lib/ash_hooks/plug.ex) is an optional synchronous HTTP
adapter. It and [AshHooks.BodyReader](../../lib/ash_hooks/body_reader.ex) exist
only when the optional HTTP dependency is installed. The adapter resolves a
fixed single-tenant declaration or uses a host resolver for source, tenant,
scope, connection context, and signature-header selection. Resolved source
snapshots follow ADR-0014. Request-controlled strings never select modules or
establish trusted tenants by themselves.

The endpoint reader caches exact pre-parser bytes across chunks. Hosts with
their own reader use `put_raw_body/2` and `raw_body/1` to exchange the complete
body through a public contract. Cached bytes take priority; otherwise the
adapter reads bounded chunks itself. Parsed parameters are never re-encoded.
A body consumed by an earlier parser without a cache is a configuration failure,
not a verified empty payload. Reader caching can be restricted by path prefix;
parser limits govern preceding reads, while adapter limits govern its own reads.

The adapter obtains raw bytes, consults optional provider `handshake/1` before
method and signature checks, and calls `Ingress.ingest/4` once for delivery.
A handshake response writes no receipt. A configured public URI supplies any
signed request URI; connection host and scheme are not trusted to reconstruct
it. A missing or repeated configured signature-header line is unsigned.

After ingest, response precedence is provider `response/1`, host `:respond`,
then public `default_response/2`. The default maps processed, permanently
failed, and superseded receipts to 200; other successful ledger outcomes to
500; signature, timestamp, and malformed-payload errors to 400; `UnknownSource`
to 404; key kind and unknown-key errors to 500; and unavailable or unrecognized
failures to 503 with a retry hint. These acknowledgments do not promise business
success for permanently failed work.

Pre-ingest refusals have separate fixed statuses for absence, unavailability,
method, size, and consumed-body errors. A host refusal policy can shape headers
and bodies but cannot change required status or headers. Custom ingest response
policies own their headers. Every response is sent and the connection halted.

## Consequences

Hosts mount the adapter outside browser-session pipelines, configure the
pre-parser reader or supply complete bytes, establish trusted resolution and
public URI policy, and choose any protocol-specific responses. Custom pipelines
retain direct ingress composition. The HTTP adapter supplies no separate queue
or async processing runtime.
