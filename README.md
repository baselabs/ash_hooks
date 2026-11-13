# AshHooks

[![Hex.pm](https://img.shields.io/hexpm/v/ash_hooks.svg)](https://hex.pm/packages/ash_hooks)
[![CI](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml)

Webhooks for [Ash Framework](https://ash-hq.org), in both directions:

- **Inbound**: verify webhooks from any sender, deduplicate them on a ledger (a
  table that records every delivery), and run your handler at least once with
  durable deduplication.
- **Outbound**: sign and deliver your own webhooks with retries, backoff, and
  dead-lettering through Oban or your own scheduler.

The two halves work independently: if you only receive webhooks, you need no
queue infrastructure at all.

- **Verify any sender.** Describe a sender's signature scheme in a few lines of
  configuration: HMAC (hash-based message authentication code) with SHA-1,
  SHA-256, SHA-384 or SHA-512; RSA signatures, PKCS#1 v1.5 or RSA-PSS (the
  probabilistic signature scheme); ECDSA (elliptic curve digital signature
  algorithm) on P-256 or P-384; Ed25519; or a JWS (JSON Web Signature) body. The
  signature can sit in a header, a structured `t=...,v1=...` header, or the body
  itself, hex or base64 encoded, over any signed input, with timestamps, a replay
  window, and key rotation. When configuration cannot express a scheme, one
  callback can, written with the same public primitives.
- Duplicate and replayed deliveries are deduplicated on the ledger: exactly one
  row per delivery, and a crash mid-flight resumes on redelivery instead of
  losing the event (handlers run at least once).
- Outbound webhooks follow the [Standard Webhooks](https://www.standardwebhooks.com)
  spec, so receivers verify them with any conformant library. Key rotation and a
  legacy-envelope mode for receivers mid-migration are built in.
- Retries honor `Retry-After`, back off with jitter, dead-letter at a ceiling,
  and durably disable endpoints that return 410. A DNS failure is a transport
  error: a hostname that stops resolving retries, labeled `nxdomain` or
  `resolve_timeout`, and only a validated private or loopback answer
  dead-letters immediately.
- Safe defaults: inbound declarations use secret resolvers rather than literal
  binaries, and endpoint rows store secret references. Endpoint URLs are checked
  against server-side request forgery (SSRF) at registration and again at send
  time, and response bodies are never stored unless you opt in for a diagnostic
  run. Inbound ledgers retain decoded payloads and a digest of the signed bytes;
  outbound ledgers retain the exact bytes to send. Read access is yours to
  govern: the package injects no read policies (see [Security](#security)).
- Telemetry events for the whole send and receive lifecycle, with classified
  reasons and identifiers rather than bodies or signing secrets.

Requires Elixir ~> 1.20 (OTP 28+) and Ash >= 3.37.2, < 4.0. Add Oban (~> 2.20)
for the generated delivery worker, and Phoenix or Plug for the HTTP ingress.
Direct delivery and signature verification work without either dependency. The
package follows semantic versioning over a named public surface; see
[Stability](#stability).

## Installation

```elixir
def deps do
  [
    {:ash_hooks, "~> 3.0"},
    # only for outbound delivery:
    {:oban, "~> 2.20"}
  ]
end
```

Or run `mix igniter.install ash_hooks`, which also tries to patch your
endpoint's `Plug.Parsers` with a raw-body reader. Signature schemes sign the
exact wire bytes, and a router plug cannot recover what the parser already
consumed, so if the automatic patch didn't apply, add it yourself:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  pass: ["*/*"],
  body_reader: {AshHooks.BodyReader, :read_body, []},
  json_decoder: Phoenix.json_library()
```

By default every parsed request carries a cached copy of its raw body; pass
`[only: ["/webhooks"]]` as the reader's third element to limit that memory cost
to your webhook routes.

You also create your own tables: ash_hooks injects fields and identities onto
your resources, and your migrations carry them, including the unique indexes the
deduplication guarantee rests on. Complete, runnable migrations, resources, and
setup are in the
[get-started tutorial](documentation/tutorials/get-started.md).

Upgrading from 2.x? 3.0 removes the built-in vendor verifiers and requires an
explicit `provider` on every inbound declaration. [UPGRADING.md](UPGRADING.md)
gives the replacement configuration for each removed module.

## Receiving webhooks

### 1. Describe the sender

A provider module describes how one sender signs its requests. For most senders,
configuration is all it takes:

```elixir
defmodule MyApp.Webhooks.Payments do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:structured_header, "x-payments-signature", signature_key: "v1"},
      timestamp: {:signature_field, "t"},
      signed_input: [:timestamp, ".", :body],
      tolerance_seconds: 300
    ]
end
```

This one reads `x-payments-signature: t=1731312000,v1=5257a8...`, checks the
lowercase-hex HMAC-SHA256 of `timestamp.body` in constant time, accepts any
listed `v1` signature (so the sender can rotate keys), and rejects a valid
signature whose timestamp is more than 300 seconds from the clock. Options are
checked when the module compiles.

The [Verify any sender](documentation/tutorials/verify-any-sender.md)
guide has recipes for common shapes: an HMAC of the body in a header, a prefixed
signature, hex or base64 secrets, Standard Webhooks, signed method and URL,
sorted form fields, RSA and ECDSA headers, Ed25519, JWS bodies, custom timestamp
formats, and two schemes on one route. `AshHooks.Provider.Scheme` documents
every option. When a scheme needs something configuration cannot express,
implement `verify_signature/3` with the public primitives in
`AshHooks.Provider.Signature`.

ash_hooks ships no vendor-specific verifiers. A sender's documentation is the
authority on its scheme, and a scheme change on the sender's side never waits on
an ash_hooks release.

### 2. Declare the source on a ledger

```elixir
use Ash.Resource,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshHooks, AshHooks.InboundDelivery]

webhooks do
  inbound :payments do
    provider MyApp.Webhooks.Payments
    secret {:app_env, [:my_app, :payments_webhook_secret]}
  end
end
```

Secrets are always sources, never literal values: an `{m, f, a}` callback, an
`{:app_env, path}`, a zero-arity function, or (for multi-tenant apps) a
one-arity function that receives the tenant. For public-key schemes the source
returns the sender's public key, PEM-encoded.

The inbound name (`:payments`) identifies the source in the ledger. `provider`
is required.

### 3. Receive with AshHooks.Plug

`AshHooks.Plug` runs the whole pipeline: verify the signature over the raw bytes,
persist the payload, deduplicate, claim under a lease (a time-limited ownership
claim; rows whose worker died are reclaimed when it expires), run your handler,
and record the outcome.

Configure the raw-body reader on your Phoenix endpoint, then forward a route
from the router. Keep webhook routes outside browser/session/CSRF pipelines:

```elixir
# MyAppWeb.Endpoint, before the router
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Jason,
  body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}

# MyAppWeb.Router: a fixed source on a single-tenant ledger
forward "/webhooks/payments", AshHooks.Plug,
  resource: MyApp.WebhookLedger,
  source: :payments,
  request_uri: "https://hooks.example.com"
```

If no parser has read the body, the plug reads it itself. A preceding parser
must cache the exact bytes with `AshHooks.BodyReader` or the host contract below;
parsed params cannot reproduce signed bytes.
If your endpoint already has its own body reader, it can instead call
`AshHooks.BodyReader.put_raw_body(conn, complete_bytes)` from its `Plug.Parsers`
`body_reader` or before parsing. Supply the complete body exactly as sent, never
a partial or re-encoded body. The plug retrieves it with
`AshHooks.BodyReader.raw_body/1` and does not read it again.
The plug sends and halts with 200 for terminal deliveries, 500 for retryable
ledger outcomes, 400 for invalid signatures, stale timestamps or malformed
payload errors, and 503 for paused sources, missing secrets or storage failures.
Every default 503 includes `retry-after: 60`; set `retry_after:` to another positive
number of seconds. Provider and host response policies own their own 503 headers.
It accepts POST by default; other methods get 405 with `allow`. Direct reads
default to an 8,000,000-byte limit (413 when exceeded); configure parser limits
separately when using `Plug.Parsers`.

When sender event IDs are unique only within an account, extend the ledger's
deduplication identity with a non-nullable scope attribute:

```elixir
inbound_delivery do
  scope_identity [:account_id]
end

attributes do
  attribute :account_id, :string, allow_nil?: false
end
```

Generate the matching database unique index. For routes such as
`/webhooks/:provider/:endpoint_id`, forward the prefix and resolve the stored
endpoint and its scope. The path is a lookup key, never a module or tenant
to trust directly. For a multitenant ledger, also declare Ash attribute
multitenancy as described in the
[tenancy checklist](documentation/tutorials/tenancy-adoption-checklist.md):

```elixir
forward "/webhooks", AshHooks.Plug,
  resource: MyApp.WebhookLedger,
  resolve: {MyApp.Webhooks, :resolve, []},
  request_uri: "https://hooks.example.com"

defmodule MyApp.Webhooks do
  def resolve(%Plug.Conn{path_info: [provider, endpoint_id]}) do
    case MyApp.Integrations.find_webhook_endpoint(provider, endpoint_id) do
      {:ok, endpoint} ->
        {:ok, %{source: endpoint.source, tenant: endpoint.organization_id,
                scope: %{account_id: endpoint.account_id}, connection: endpoint.connection}}

      {:error, :not_found} -> {:error, :not_found}
      {:error, _reason} -> {:error, :unavailable}
    end
  end

  def resolve(_conn), do: {:error, :not_found}
end
```

The resolver receives the conn followed by its configured arguments. A missing
endpoint answers 404; an unavailable lookup answers 503. Both write nothing.
Use the resolver for every multitenant ledger, and for any ledger that declares
`scope_identity` slots. Its scope keys must match that declaration.

A provider written directly against `AshHooks.Provider` reads its signature only
from `ctx.signature`. Set `signature_header: "x-signature"` on the plug, or return
`:signature_header` from the resolver, to name the header that carries it.

`request_uri` accepts a public base URL (the original path and query are appended)
or `{module, function, args}` returning the full public URI. It defaults to no
URI. It never uses the conn's host, scheme or port, which may be internal behind
a TLS proxy.

Implement the optional provider `handshake/1` for subscription challenges; it
can answer before method and signature checks without writing a delivery.
For sender-specific acknowledgments, provider `response/1` has precedence over
the plug's `respond: {module, function, args}` policy. Either may return `:default`
to fall through. Policies receive exactly the ingest outcome; they do not alter
the plug's own refusals. `AshHooks.Plug.default_response/2` takes the outcome and
the plug's validated options, including `retry_after:`, to expose the same mapping.

For refusal bodies, set `refuse: {module, function, args}`. It receives one of
`:not_found`, `:unavailable`, `:method_not_allowed`, `:too_large`, or
`:body_consumed`, followed by the configured arguments, and returns
`{headers, body}` or `:default`. The status stays fixed. Required `allow` and
`retry-after` values take precedence over conflicting host headers.

The lower-level path remains available for custom transports and pipelines:

```elixir
outcome = AshHooks.Ingress.ingest(MyApp.WebhookLedger, :payments,
  AshHooks.BodyReader.raw_body(conn), %{headers: conn.req_headers, method: conn.method,
    scope: %{account_id: account_id}, tenant: tenant})
opts = AshHooks.Plug.init(resource: MyApp.WebhookLedger, source: :payments, retry_after: 60)
{status, headers, body} = AshHooks.Plug.default_response(outcome, opts)
conn |> Plug.Conn.merge_resp_headers(headers) |> Plug.Conn.send_resp(status, body) |> Plug.Conn.halt()
```

Supply `request_uri` in the lower-level ctx when the scheme signs the public URL.

### 4. Handle the event

A configured provider classifies every verified request as `:webhook` and
returns an `AshHooks.Provider.Event` holding the payload. Override
`parse_event_type/1` and `handle_event/2` in the same module to map the sender's
event names to your own atoms and run your application's actions:

```elixir
defmodule MyApp.Webhooks.Payments do
  use AshHooks.Provider, verify: [...] # the options shown in step 1

  @types %{"charge.succeeded" => :charge_succeeded}

  @impl true
  def parse_event_type(%{"type" => type}) do
    case Map.fetch(@types, type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unknown_event_type}
    end
  end

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  # return {:ok, result} or {:error, :retry | :permanent, reason}
  @impl true
  def handle_event(:charge_succeeded, payload), do: MyApp.Billing.record_charge(payload)
end
```

Map event names with an explicit table; never call `String.to_atom/1` on request data.
An unknown type is recorded as a permanent failure.

**Delivery semantics.** A terminal delivery (`:processed`, `:failed_permanent`,
or `:superseded`) is never processed again. A crash after your handler ran but
before the ledger recorded it will re-run the handler on redelivery, so write
handlers idempotent, keyed on the logical event or batch identity (for
action-level idempotency elsewhere in your app, the sibling package
[`ash_onetime`](https://hex.pm/packages/ash_onetime) is an optional companion).
Permanent failures belong on your operator surface; the successful
acknowledgment prevents a sender from retrying a row that cannot run again.

The deduplication identity comes from the declaration's `event_id` extractor,
then the provider's optional `event_identity/1` callback, then the SHA-256 of
the raw body.

`claim_delivery/3`, `mark_processed/4`, and friends are public if you want to
drive the lease machine from your own async pipeline; `AshHooks.Ingress.reap/2`
re-drives deliveries whose claims died with an expired lease.

### Payload formats

JSON is the default. Opt into flat `application/x-www-form-urlencoded` decoding
on a route with `body_format :form`, or implement the provider's optional
`body_format/0` callback returning `:form`. Names and values are URL-decoded;
bracket notation remains literal, and repeated names keep their last value in the
stored map. Invalid UTF-8 names or values become a permanent malformed payload,
matching JSON's failure handling. **Verification always receives the original raw
bytes**, before decoding. The request's Content-Type cannot opt a route into a
decoder.

```elixir
inbound :sms do
  provider MyApp.Webhooks.Sms
  body_format :form
  secret {:app_env, [:my_app, :sms_webhook_secret]}
end
```

Providers may implement `decode_payload/1` for a signed envelope (a configured
JWS-body provider generates one); an explicit route `body_format` overrides it.

### Rotation, pausing, and inbound queries

- `previous_secret` on an inbound declaration takes the outgoing key's source:
  both keys verify until you remove the option. Tenant-aware (one-argument)
  `previous_secret` and `paused` callbacks receive the resolved tenant on
  multitenant ledgers.
- `paused` refuses requests with `{:error, :source_paused}` before verification
  or any write; answer 5xx and the sender retries, so nothing is lost.
- `AshHooks.Ingress.list/2` queries inbound deliveries by source, status, event
  type, and time range; `counts/2` answers a window's received, duplicate,
  failed-verification, and handler-failure counts (`ingress_tracking :on`).

### HTTP Message Signatures with RequestSeal

For senders that sign with [HTTP Message Signatures (RFC 9421)](https://www.rfc-editor.org/rfc/rfc9421.html),
use [RequestSeal](https://hex.pm/packages/request_seal) 1.0 or later
(`{:request_seal, "~> 1.0"}`) alongside ash_hooks. It verifies which parts of the request are covered
(method, authority, path, query, and named headers), checks signature freshness
and expiry, verifies body integrity with content digests
([RFC 9530](https://www.rfc-editor.org/rfc/rfc9530.html)), and spends each
signature's nonce once through a replay store you choose (ETS, Erlang Term
Storage; PostgreSQL; or `ash_onetime`). Keys come from a resolver you write, and its bounded key
discovery handles JSON Web Key Sets (JWKS) and key directories; it also verifies Web Bot Auth agents
and crawlers. Its `RequestSeal.AshHooks` adapter verifies inside an ash_hooks
provider, and `RequestSeal.AshHooks.Http` signs your outbound ash_hooks
deliveries with RFC 9421. ash_hooks keeps the ledger, retries, and transport.
The [Verify any sender](documentation/tutorials/verify-any-sender.md#http-message-signatures-rfc-9421-with-requestseal)
guide shows the provider.

## Sending webhooks

Declare the event on the emitting resource, point it at your
subscription and delivery resources, and define one worker module:

```elixir
defmodule MyApp.WebhookDeliveryWorker do
  use AshHooks.Worker,
    deliveries: MyApp.OutboundDelivery,
    endpoints: MyApp.WebhookEndpoint,
    secret_resolver: {MyApp.Secrets, :webhook_secret},
    queue: :webhooks
end
```

The secret resolver maps an endpoint's secret reference to its value:
generate values with `AshHooks.Signing.generate_secret/0`, store them
whole in your secret store, and return them unchanged.

Related budgets are checked at compile time: the macro refuses an Oban
`:max_attempts` at or below `:delivery_max_attempts` (only the row's
ceiling decides dead-letter), a literal `http_opts` `timeout:` at or above
`:attempt_timeout`, non-positive budget values, and a literal
`validate_destination: false` outside `:test` (it is the loopback test
seam). Timing is also configurable at runtime: pass
`runtime_config: {MyApp.Config, :webhook_runtime}` and the callback
resolves `:delivery_max_attempts`, the backoff ladder, the `Retry-After`
cap, `:attempt_timeout`, and `:finalization_allowance` per perform; every
compile-time misfit check re-runs against the resolved set, so an override
that overruns the baked job envelope fails the job before any delivery
work. See `AshHooks.Worker` for every relation and its rationale.

Dispatch, wiring the worker's generated enqueue function:

```elixir
{:ok, event} =
  AshHooks.Event.new(
    type: :order_paid,
    payload: Jason.encode!(%{order_id: order.id}),
    # Reuse this ID when retrying the same logical event.
    id: "msg_order-" <> to_string(order.id)
  )

AshHooks.dispatch(Order, :order_paid, event,
  enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}
)
```

Every matching enabled endpoint gets a durable delivery row carrying
the exact bytes to sign. The worker signs per Standard Webhooks (the
same `webhook-id` on every retry), succeeds only on 2xx, never follows
redirects, honors `Retry-After` (bounded) on 408/429/5xx, backs off
with jitter when the header is absent (5xx, transport errors), dead-letters other
client errors, and
durably disables the endpoint on 410. An endpoint's failure never
blocks delivery to its siblings.

**Without Oban**, dispatch still works (every matching endpoint gets a
durable `:pending` row), but nothing drives those rows until you define
the worker (or call `AshHooks.Delivery.run/2` yourself): the delivery
row owns the retry policy, and the queue is only its trigger
(architecture decision record
[ADR-0008](https://github.com/baselabs/ash_hooks/blob/main/docs/adr/0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md)).

The default HTTP adapter bounds response headers, retained body bytes, and
the complete operation time. OTP's `:httpc` is an alternative with additional
buffering limits described in its module docs. You can also provide an adapter
for your application's transport requirements.

### Optional outbound policy

All three options are off by default. The worker and direct delivery runner
accept:

- `retryable_statuses: [408, 409, 425, 429, 500, 502, 503, 504]` replaces the
  retryable HTTP-status set. Omit it for the default (408, 429 and 5xx); use `[]`
  to make every ordinary HTTP failure final. `Retry-After`, backoff, and ceilings
  apply to configured retry statuses. Success on 2xx, redirect refusal, and the
  durable 410 disable rule remain fixed. Transport errors keep the default retry
  policy.
- `delivery_headers: {MyApp.Webhooks, :headers}` calls
  `headers(delivery, endpoint, tenant)` before each send. Return a header map or
  list of binary pairs. Direct-run configuration also accepts that map/list or
  a three-argument function. Names are checked case-insensitively: hosts cannot
  override `webhook-id`, `webhook-timestamp`, `webhook-signature`,
  `x-webhook-signature`, Content-Type, Host, or HTTP framing/connection headers.
  Host metadata such as `x-webhook-event`, trace IDs, and dates is allowed.
  Invalid headers and callback failures retry without sending; their values
  never become error summaries.
- `certificate_pin: {MyApp.Webhooks, :pin}` calls `pin(endpoint, tenant)` so a
  host can choose a pin per endpoint. Return `nil` for off, `{:certificate, der}`
  for the exact leaf certificate, `{:sha256, digest}` for its SHA-256, or
  `{:spki_sha256, digest}` for the DER SubjectPublicKeyInfo SHA-256. Digests are
  32 raw bytes. Direct configuration also accepts the pin or a two-argument
  function. A static host pin can be supplied in `http_opts[:certificate_pin]`;
  a configured resolver takes precedence, including an explicit `nil` result.
  The pin requires HTTPS and `AshHooks.Http.Bounded`; it adds to normal CA,
  hostname/IP-SAN, SSRF, and deadline checks. Mismatch, invalid pin, or resolver
  failure closes the attempt without a request and records a non-retryable
  failure. Default: off. Load computed worker pins through the callback or the
  existing `http_opts: {module, function, args}` runtime seam.

All callbacks resolve from current host configuration on each attempt. They need
no tables, endpoint attributes, process-local state or extra dependencies.

Schedule `AshHooks.reconcile_pending/3` for each declaration and tenant using
the same named worker callback. It repairs enqueue gaps, due retries, expired
send leases, and pending endpoint disables while preserving retry times and
attempt counts. Delivery rows retain their declaration and route, so one
declaration cannot recover another's work. Anonymous enqueue callbacks can use
a stable `enqueue_key` for recovery. Application nodes must keep UTC clocks
synchronized for lease decisions.

Each result belongs to a live, fenced attempt. Network delivery remains
at-least-once: a receiver may accept a request before its sender dies. Receivers
deduplicate by the stable `webhook-id`.

**Delivery logs and attempt history.** Add the `AshHooks.OutboundAttempt`
extension on a resource and pass `attempts:` to the worker: every attempt
records one durable row (time, outcome, classified reason, HTTP status,
latency, the signing key reference but never the secret), queryable by
endpoint, outcome, event type, and time range with keyset pagination
(`AshHooks.Delivery.list/2` and `AshHooks.OutboundAttempt.list/2`). Response
bodies stay off unless an endpoint opts in per row
(`response_capture_attributes :on` + `response_capture: true`): captured
bytes are bounded, redacted, and only allowlisted response headers are kept.

**Response bodies are never stored by default**: each delivery row keeps the
status and a content-type summary. For a diagnostic run, enable capture on one
row. The captured body is bounded, passes built-in redaction, and is marked
`[captured]` in the snippet:

```elixir
# Diagnostic capture for one row. Supply the resource and resolver config;
# retry overrides are independent of the worker's configured settings.
AshHooks.Delivery.run(
  %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
  snippet_capture: true,
  deliveries: MyApp.OutboundDelivery,
  endpoints: MyApp.WebhookEndpoint,
  secret_resolver: {MyApp.Secrets, :webhook_secret},
  max_attempts: 10, base_backoff_seconds: 2,
  max_backoff_seconds: 3600, retry_after_cap_seconds: 86_400
)
```

The driver defaults to the retry values shown. Its `max_attempts` option
controls the delivery row; the worker calls that option `delivery_max_attempts`
because the worker's `max_attempts` controls Oban jobs. Copy the worker's
retry policy for a diagnostic run: a lower delivery ceiling can dead-letter a
row the worker would still retry.

Only non-terminal rows are driven: a row that already finished will
not re-send; re-drive a failed one, or wait for its retry.

For a domain-specific denylist, also pass a `snippet_redactor`
(`{module, function}` or `fn body -> body | nil`; return the
redacted binary, or nil to leave the body uncaptured). It runs before
the built-in redaction; a crashing redactor leaves the body
uncaptured. See `AshHooks.Worker` for the worker-macro form.

**Test events.** `AshHooks.Delivery.test_send/2` sends a signed synthetic
event of a chosen type to one endpoint, outside subscriptions: a fresh
webhook id each time, a payload that marks itself as a test, and the
normal attempt/telemetry lifecycle behind it (see `AshHooks.Delivery`).

**Signing modes.** `:standard` (default) needs only the endpoint's
`secret_ref`. `:dual` and `:legacy` additionally require a
`legacy_secret_ref`: `:dual` emits both envelopes so receivers can
migrate, `:legacy` emits only the old one.

**Secret rolling.** Roll an endpoint's signing secret with an overlap
window (`AshHooks.Endpoint.roll_secret/2` + `key_lifecycle :on`): the
incumbent reference moves to `previous_secret_ref`, BOTH keys sign every
delivery until the window ends (Standard Webhooks multi-signature), the
scheduled sweep retires the old key on time, and the row exposes each
key's created, first-used, and retired times, never secret material.

**Endpoint health and auto-disable.** `AshHooks.EndpointHealth.stats/2`
computes one endpoint's trailing-window success rate, latency
percentiles, and first-attempt vs eventual successes from the attempt
history; the endpoint's `auto_disable` policy (a duration and failure
share beside the existing 410 rule) disables sustained failures through
the same durable switch, warning first
(`[:ash_hooks, :endpoint, :disable_warning]`) so your notify surface can
reach people before the breaker opens. Re-enabling is explicit.

**The event catalog and version pinning.** The `outbound` DSL declares
each event type's `description`, `payload_schema`, `example`, and
`version`; `AshHooks.Catalog` reads the catalog back for event pickers
and doc generation. An endpoint that pins a payload version
(`version_pinning :on`) receives that variant builder's exact bytes;
per-endpoint rows carry their own version.

**The event log.** `AshHooks.OutboundEvent` records each dispatched event
once (id, type, version, exact bytes) whether or not any endpoint was
enabled, with its own retention, and `replay/3` delivers one event or a
filtered set to any chosen endpoint, including one added later, keeping
the event id so receivers deduplicate.

**Subscription attribute filters.** `filter_attributes([:order_id,
:region])` on the subscription resource lets a subscription match on
declared event attributes (values ride the event's `metadata`), evaluated
before any delivery row exists: multiple filters AND, list values
any-of, unknown keys never match.

**Transports.** `AshHooks.Transport` routes one endpoint's deliveries to
your own transport (a developer's local forwarder behind a CLI `listen`
command) instead of HTTP, with the same signing, attempts, and telemetry. A
destination policy (`AshHooks.DestinationPolicy`) adds your own allow and
deny rules around the packaged SSRF check.

## Fitting the extensions to your domain

The injected fields and actions carry opinionated names by default;
your domain may reserve those names or own the lifecycle itself.
Every knob is a per-resource DSL option, fail-closed at compile:

```elixir
# your domain reserves `payload` for its own sole payload store:
# rename the ledger's exact-bytes column instead
outbound_delivery do
  payload_attribute :event_bytes
end

# append-only audit ledger: no destroy action is injected, and
# the retention hook fails loud (deletion is your own surface)
outbound_delivery do
  payload_attribute :event_bytes
  prune_action :none
end

# your register already has an enable switch: map the durable
# enable/disable onto it (the 410 breaker and operators flip your
# attribute; the package injects no `status` of its own)
endpoint do
  status_attribute :active
  enabled_values [true]
  disabled_value false
end
```

Ledger operations use the complete resource primary key, including custom and
composite keys. Every component needs a default, a data-layer generator, or a
supported create input; inbound scope fields can supply key components.
Endpoint and subscription references require a single UUID-compatible
key, which may be renamed or generated with `uuid_v7_primary_key`.
A subscription register may be a closed `{:array, :atom}` enum
(your constraints, your default; matching handles atoms and strings
identically, wildcard included), and injected-PK ledgers still classify
`:created`/`:duplicate` exactly.

**Policies.** The package injects write actions, not the authorization
around them. Cover the generated machine actions with an action-specific
policy of your own (the runtime's internal calls bypass policies by
design), or keep the resources off every actor-facing surface; the
full action set and obligation are stated at each extension site in the module docs.

## Observability

Attach one handler to see the whole lifecycle: inbound
verify/dedup/claim, enqueue failures, delivery
attempt/result/backoff/dead-letter/endpoint-disable. Events carry ids,
integers, fixed atoms, and classified reasons, never secrets, bodies,
or payloads. The exact event list and a copy-paste `attach_many` block
are in the `AshHooks.Telemetry` docs and the
[get-started tutorial](documentation/tutorials/get-started.md).

## Retention

Ledger and delivery rows accumulate by default (they are the dedup and
audit record). When you want them bounded, drive the retention hooks on
a schedule of your choosing (an Oban cron job, a mix task, a nightly
job):

- `AshHooks.Ingress.prune/2` and `AshHooks.Delivery.prune/2` delete
  terminal rows older than a cutoff; retryable and in-flight rows are
  never touched. They key off the resource's `inserted_at`, so add
  Ash's `timestamps()` to the resource and its migration. Append-only
  ledgers may omit the destroy action entirely
  (`prune_action :none`); `prune/2` then fails loud with a named
  error, and deletion is your own surface.
- `AshHooks.Ingress.redact_payload/5` rewrites a claimed row's payload
  under the claim fence (scrub sensitive fields while keeping the dedup
  identity; the original-bytes digest is preserved for audit).

Deleting a terminal row re-opens its dedup identity (a replayed
webhook re-processes, a re-emitted outbound event re-sends), so set the
TTL beyond any replay or re-emission horizon.

## Multi-tenancy

If one app serves multiple organizations, ash_hooks works the way Ash
does: declare **attribute multitenancy** on the four resources (your
Subscription, Endpoint, inbound ledger, and outbound delivery ledger)
and pass a `:tenant` to every call:

```elixir
# the four resources declare the same contract
multitenancy do
  strategy :attribute
  attribute :org_id
end

# outbound: the tenant scopes the fanout, endpoint resolution, and rows
AshHooks.dispatch(Order, :order_paid, event, tenant: org.id)

# inbound: the tenant rides the request context
AshHooks.Ingress.ingest(WebhookLedger, :payments, raw_body, %{
  headers: conn.req_headers,
  tenant: org.id
})
```

From there, isolation is enforced by the data model: a dispatch for
tenant A cannot create a delivery row for tenant B's endpoint, a
subscription pointing at another tenant's endpoint id resolves to
not-found and is skipped, the inbound dedup identity is per-tenant, and
the claim fence and every mark are per-tenant. Touch a multitenant
resource without a tenant and you get `{:error, :tenant_required}`
before any data access; mix tenancy declarations across the resources
one operation touches (say, a tenant-scoped delivery ledger beside an
undeclared endpoint table) and you get `{:error, :tenancy_mismatch}`.
Both are named errors, and both fail closed. Each operation checks the set it
actually reads: an inbound-only app declares tenancy on its ledger
alone and needs none of the outbound resources.

The async path is tenant-aware too: the Oban job args include the
row's tenant (the worker recovers full context after any restart), the
retention sweeps take a `:tenant` (with `AshHooks.reap_all/2` /
`AshHooks.prune_all/2` sugar to sweep a tenant list), and
`AshHooks.reconcile_pending/3` repairs rows stranded between the row
write and the enqueue, per tenant, with single-winner semantics. If
your signing secrets are per-tenant, resolution can be too: the worker
macro's `tenant_aware_secrets: true` (the resolver becomes
`f(ref, tenant)`), an inbound `secret fn tenant -> {:ok, secret} end`,
and an optional provider `webhook_signing_secret(connection, tenant)`
callback.

Single-tenant app? Do none of this. No tenant passed means no tenant
threaded; behavior is identical.

Adopting tenancy on tables that already have rows is an ordered
transition (backfill, then regenerate indexes, then enable); the
[adoption checklist](documentation/tutorials/tenancy-adoption-checklist.md)
walks it.

## Security

Signatures are compared in constant time. Secret values come from your
configured sources. Endpoint URLs are checked at registration and send time;
the supplied adapters connect to a validated address to prevent DNS rebinding.
The default adapter bounds HTTP reads, and diagnostic response capture runs
through redaction before storage.

Your resource policies govern access to the ledgers. Inbound rows contain
decoded provider payloads, signed-body digests, event IDs, and scope keys;
outbound rows contain exact event bytes. Those payloads can contain personal
information. Define read policies that deny access by default:

```elixir
policies do
  # deny by default; open exactly what your app needs
  policy action_type(:read) do
    authorize_if actor_attribute_equals(:admin, true)
  end
end
```

This assumes `Ash.Policy.Authorizer` in the resource's `authorizers`;
match the snippet to your actual actors. The `policies` block lives
inside the ledger/delivery resource module (with
`authorizers: [Ash.Policy.Authorizer]` in the `use Ash.Resource`
options; Ash's [policies guide](https://hexdocs.pm/ash/policies.html)
covers the full model). Vulnerability reports:
[SECURITY.md](SECURITY.md), never a public issue.

## Stability

ash_hooks follows semantic versioning over a named public
surface (the DSL, the public modules, injected attributes/actions,
telemetry events, error classes). The current major is 3: breaking changes next ship in 4.0,
deprecations run at least two minor releases, and safety corrections ship as fixes
([ADR-0010](https://github.com/baselabs/ash_hooks/blob/main/docs/adr/0010-semver-and-support-policy.md)).

Minimum supported versions: Elixir ~> 1.20 (OTP 28+; CI-tested on
Erlang/OTP 28 and 29), Ash >= 3.37.2 and < 4.0, Oban ~> 2.20 (optional, outbound only).
Development is supported on macOS and Linux; Windows developers use WSL2.
CI runs on Linux, including an AshPostgres leg exercising a
`uuid_v7`-keyed consumer shape. On Ash 3.33+ your
application must also set Ash's required `default_string_length_count`
config: an Ash requirement for every app compiling resources, not an
ash_hooks one ([UPGRADING.md](UPGRADING.md)). One nuance: a fix
that closes a safety hole can change behavior in a patch release (a
delivery that wrongly succeeded may now retry, for example); such
corrections are always called out under "Fixed" in the
[CHANGELOG](CHANGELOG.md). Moving off a supported version is a minor
release with an [UPGRADING.md](UPGRADING.md) note.

## Further reading

- [Get started](documentation/tutorials/get-started.md): a complete walkthrough,
  migrations included
- [Guided tour (Livebook)](documentation/livebooks/get-started.livemd): run the
  whole library inside one notebook
- [Verify any sender](documentation/tutorials/verify-any-sender.md): signature
  recipes and the provider configuration reference
- [UPGRADING.md](UPGRADING.md): migration notes per release
- [SECURITY.md](SECURITY.md): reporting and scope
- [DSL reference](documentation/dsls/DSL-AshHooks.md)
- [Architecture decisions](https://github.com/baselabs/ash_hooks/tree/main/docs/adr):
  the reasoning behind every major design choice
- [CONTRIBUTING.md](CONTRIBUTING.md): setup, the gate suite, and how to propose
  changes; GitHub issues are the support channel
- Full API docs at [hexdocs.pm/ash_hooks](https://hexdocs.pm/ash_hooks)

## License

MIT.
