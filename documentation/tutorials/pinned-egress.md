# Pinned egress

`AshHooks.Egress` sends one HTTP/1.1 request over a socket it owns. Webhook
delivery uses the same engine through `AshHooks.Http.Bounded`. Each attempt
resolves once, validates every DNS answer with `AshHooks.Ssrf`, and connects
to a validated address. Host, TLS SNI, and certificate verification retain
the original host. Literal addresses require an IP subject alternative name.
An optional leaf certificate pin supplements normal trust and identity checks.

## Enroll a destination

The host chooses and enrolls the destination, persists its plain fields on its
own record, and selects that record for each admitted request. HTTPS is the
default. Userinfo, fragments, unsafe literal addresses, and metadata hosts
are refused without DNS. Store an opaque identifier for telemetry, with no
credential or payload data in that identifier.

<!-- not-run: Enrollment and storage require the host's destination record and endpoint. -->
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

Pass an effective absolute URL or an absolute path and query. Bind non-nil
credentials per admitted request, after selecting the destination. Request
headers and body remain the host's responsibility; authority, connection,
and length headers belong to the transport.

<!-- not-run: Sending requires an enrolled host destination and bound request credentials. -->
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

<!-- not-run: The host supplies the destination and its incremental consumer. -->
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

ash_hooks never retries. The host records an intent before sending and
classifies a killed process or lost node from that record: no result can
arrive after process or node loss. The host also owns admission, interrupted
or ambiguous outcomes, credential binding, and refusing alternate transports.

## Req

Req is optional. Attach the destination through private request data. Require
`redirect: false`; any `follow_redirects` option is refused, including false.
Use `retry: false` or effective `max_retries: 0`. Installed retry functions
with zero retries are accepted. An adapter-returned request carries an attempt
latch, and Req's private retry count also refuses a second run before I/O.

<!-- not-run: This composition requires Req and the host's enrolled destination. -->
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
chunks before I/O. Hosts own request size and body production. Async
`into: :self` is refused.
Response private data `:ash_hooks_completion` preserves completion.
Req response decoding and any host-added steps are outside ash_hooks' byte cap;
leave compression off and choose decoding steps appropriate for trusted data.

## ReqLLM composition

For buffered ReqLLM calls, configure
`req_http_options: [adapter: AshHooks.Egress.ReqAdapter, retry: false, redirect: false]`
and top-level `max_retries: 0`. ReqLLM's transport preserves and delegates to
the adapter. Its retry step installs a function, which the adapter accepts
only when effective retries are zero. The host's request setup attaches the
destination and binds a non-nil per-request API key. An empty key must fail
instead of falling through to global credentials.

ReqLLM streaming uses a host wrapper provider. Return
`stream_transport: :in_process` and implement `attach_in_process_stream/3`
with an `InProcessStream` cancel callback. Build the actual provider request
with its documented `attach_stream/4`, then send it with
`AshHooks.Egress.stream/8`. Decode chunks using the documented
`stream_protocol_parser/2`, `parse_stream_protocol/2`, `init_stream_state`,
`decode_stream_event/3`, and `flush_stream_state` callbacks and
`ReqLLM.Streaming.SSE`. Keep parser state across chunks, which need not align
with SSE event boundaries. The in-process client has no retry path.

The host qualifies that provider wrapper and cancellation behavior. It must
refuse alternate WebSocket transports, configured `finch_request_adapter`,
and `on_finch_request`. ReqLLM's own telemetry and errors must be filtered by
the host. ReqLLM is not an ash_hooks dependency.

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
are emitted. Keep the opaque destination identifier contents-free as well.
