# Pinned egress

`AshHooks.Egress` sends one HTTP/1.1 request over a socket it owns. Webhook
delivery uses the same engine through `AshHooks.Http.Bounded`. Each attempt
resolves once, validates every DNS answer with `AshHooks.Ssrf`, and connects
to a validated address. Host, TLS SNI, and certificate verification retain
the original host. Literal addresses require an IP subject alternative name.
An optional leaf certificate pin supplements normal trust and identity checks.

## Enroll a destination

`destination/2` validates an endpoint without DNS and returns a plain
`AshHooks.Egress.Destination` struct. HTTPS is the default. Userinfo,
fragments, unsafe literal addresses, and metadata hosts are refused.
The optional `destination_id` is carried unchanged in telemetry.

<!-- not-run: This enrollment example uses a placeholder endpoint. -->
```elixir
{:ok, destination} =
  AshHooks.Egress.destination("https://api.example.com/v1/",
    destination_id: "provider-primary"
  )
```

The scheme, lowercase host, explicit port, and path prefix constrain every
effective URL before network I/O. A path is accepted at the prefix or beneath
its slash boundary; `/v1` does not enroll `/v10`. Dot segments and backslashes
are refused. DNS is checked again for each attempt. There is no reconnect,
alternate address attempt, redirect, proxy, HTTP/2, or connection reuse.

Controlled loopback tests may use `allow_http: true` and
`validate_destination: false` at enrollment. These flags are stored with the
destination. A send cannot disable its enrolled address validation.

## Buffer or stream a response

`request/6` and `stream/8` accept an effective absolute URL or an absolute
path and query. They preserve supplied header values and body bytes.
Repeated header lines retain their order. The transport generates authority,
connection, and length headers.

<!-- not-run: This example requires a live endpoint and application request values. -->
```elixir
result =
  AshHooks.Egress.request(
    destination,
    :post,
    "/v1/messages",
    %{"authorization" => "Bearer " <> per_request_key},
    encoded_request,
    timeout: 30_000,
    max_body_bytes: 1_048_576
  )
```

Buffering defaults to 64 KiB and returns `:body_too_large` when that limit
is exceeded. Explicit `capture_limit: true` retains only the prefix and
returns completion `:capture_limit`, as delivery's bounded capture does.
Streaming has no default body cap. Chunks are decoded HTTP body bytes, not
HTTP chunk framing, and callbacks execute synchronously in the caller.

<!-- not-run: This excerpt requires a live endpoint and an incremental consumer. -->
```elixir
callback = fn
  {:status, status}, acc -> {:cont, Map.put(acc, :status, status)}
  {:headers, headers}, acc -> {:cont, Map.put(acc, :headers, headers)}
  {:data, bytes}, acc -> {:cont, consume_chunk(acc, bytes)}
end

{:ok, response} =
  AshHooks.Egress.stream(destination, :get, "/v1/events", %{}, nil, callback, initial_state,
    idle_timeout: 15_000,
    timeout: 120_000
  )

final_state = response.acc
```

Return `{:halt, acc}` to close the socket immediately, with completion
`:halted`. Callback failures return `:callback_failed`; raised values are
discarded. The response's body is nil and its `acc` is the final accumulator.
Caller death closes its socket. The total deadline starts at the call;
connect timeout includes validation, DNS, TCP, and TLS. Idle timeout bounds
time between socket reads, including time spent in callbacks. Cumulative
headers default to 32 KiB, including informational responses. HEAD, 204, and
304 responses have no body. Informational responses precede the final status;
101 is `:unsupported_upgrade`.

## Classify outcomes and retries

Errors are `%AshHooks.Egress.Error{reason, phase, sent, status}`. `sent: :none`
means no HTTP write occurred. `sent: :possible` is set immediately before
the first socket write and never goes back. It does not prove remote receipt
or completion. Messages and Inspect contain no destination or request values.
Read fields explicitly to classify failures.

A complete response has completion `:complete`. A halted stream or capped
capture leaves remote completion unknown. A 3xx response is always
`:redirect_refused`, with its status and `sent: :possible`, and never reaches
another destination. An early close in sized or chunked framing returns
`:truncated_body`; read-to-close framing completes on close.

Each call performs one attempt without retries. A killed process or lost
node returns no result. These are transport-level outcomes; the API does not
supply admission, credential management, or intent persistence.

## Req

Req is optional. The adapter reads the destination from private request data.
It accepts disabled redirects and refuses any `follow_redirects` option,
including false. It accepts `retry: false` or supported retry settings with
`max_retries: 0`. Returned requests carry an attempt latch and disabled
retries. Req's private retry count also refuses a second run before I/O.

<!-- not-run: This example requires Req and an enrolled destination for a live endpoint. -->
```elixir
request =
  Req.new(
    url: "https://api.example.com/v1/events",
    adapter: AshHooks.Egress.ReqAdapter,
    redirect: false,
    retry: false,
    decode_body: false
  )
  |> Req.Request.put_private(:ash_hooks_destination, destination)
  |> Req.Request.put_private(:ash_hooks_egress_options, timeout: 60_000)

Req.request(request)
```

`into:` callbacks receive `{:data, bytes}` and `{request, response}` following
Req 0.7's contract. Collectables receive status-200 bodies; other statuses
accumulate a binary. Request bodies are materialized from iodata or enumerable
chunks before I/O. Async `into: :self` is refused.
Response private data `:ash_hooks_completion` preserves completion.
The byte cap applies to transport bytes before Req response steps, including
any response decoding.

## Example: client-library composition

The adapter works with Req pipelines that have retries disabled. ReqLLM
1.31.0's buffered transport is one example: it preserves and delegates to a
custom Req adapter. Its `req_http_options` can select
`adapter: AshHooks.Egress.ReqAdapter`, `retry: false`, and `redirect: false`,
with top-level `max_retries: 0`. The retry function that ReqLLM installs is
accepted with zero effective retries. The destination is attached to the
resulting Req request through the private-data API shown above.

`stream/8` also accepts the method, URL, headers, and body produced by a
client-library request builder. This supplies the same pinned transport to
clients whose streams bypass Req. For example, ReqLLM 1.31.0's HTTP streams
normally call Finch directly; an in-process stream transport can instead
call `AshHooks.Egress.stream/8` and receive its status, headers, and chunks.

One such composition uses `stream_transport: :in_process`,
`attach_in_process_stream/3`, and an `InProcessStream` cancel callback. The
provider's documented `attach_stream/4` builds the request. Its
`stream_protocol_parser/2`, `parse_stream_protocol/2`, `init_stream_state`,
`decode_stream_event/3`, `flush_stream_state`, and `ReqLLM.Streaming.SSE`
can consume the chunks and retain parsing state across split SSE events.
The in-process client's path has no retry loop. Cancelling the process
running Egress closes its socket.

This is an example of composing a client library with the public transport
API. ReqLLM is not an ash_hooks dependency.

## Observe attempts

Attach to `[:ash_hooks, :egress, :start]` and `[:ash_hooks, :egress, :stop]`.
Measurements are `dns_duration_ms`, `connect_duration_ms`, `tls_duration_ms`,
`first_byte_duration_ms`, `total_duration_ms`, `bytes_sent`, and `bytes_received`.
Durations use milliseconds; byte counts include HTTP framing. `bytes_sent`
counts bytes submitted to the write, including a failed write with unknown
delivery. Use `sent` to classify the outcome. Before a first
byte, its duration is nil. Metadata is exactly `destination_id`, `scheme`,
`port`, `address_family`, `method`, `phase`, `sent`, `status`, `completion`,
and `reason`. No host, path, query, headers, bodies, or raw exception terms
are emitted. The opaque destination identifier is carried unchanged.
