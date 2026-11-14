# AshHooks

[![Hex.pm](https://img.shields.io/hexpm/v/ash_hooks.svg)](https://hex.pm/packages/ash_hooks)
[![CI](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml)

Receive, verify, and deduplicate incoming webhooks. Sign, deliver, retry, and
track outgoing webhooks with [Ash Framework](https://ash-hq.org).

A ledger is a database table that records delivery identity, state, and outcome.
Deduplication uses a unique index to retain one row per identity.

Inbound and outbound work independently. Inbound needs no queue. Outbound can
use the generated Oban worker or your own scheduler calling `AshHooks.Delivery.run/2`.

Requires Elixir `~> 1.20`, Erlang/OTP 28 or 29, and Ash
`>= 3.37.2 and < 4.0.0-0`. Add `{:ash_hooks, "~> 3.1"}` to your dependencies.
Oban `~> 2.20` is optional and required for the generated worker. Plug `~> 1.16`
is optional for HTTP receipt. Every supported Ash version requires your application
to set `default_string_length_count`; see [UPGRADING.md](UPGRADING.md).

The [get-started tutorial](documentation/tutorials/get-started.md) includes
migrations, resources, a provider, domain registration, and executable calls.
The [Livebook](documentation/livebooks/get-started.livemd) walks through both
directions with real SQLite and a real request-capture receiver.

## Receiving webhooks

A provider describes a signing contract. This application-defined example checks
a lowercase hexadecimal HMAC-SHA256 signature over `timestamp.body`. HMAC means
hash-based message authentication code. Any valid `v1` signature in the structured
header is accepted, allowing the sender to rotate keys. The timestamp must be
within 300 seconds of the clock.

<!-- tested: readme-payments-provider -->
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

Declare the provider explicitly on an inbound ledger; the source name does not
select a module. Keep the name stable because it is part of the delivery identity.
A secret source can be an `{module, function, args}` callback, `{:app_env, path}`,
a zero-argument function, or a tenant-aware one-argument function. Literal secret
strings are rejected. For public-key schemes the source returns the public key.

Providers support HMAC, RSA, ECDSA (elliptic curve digital signature algorithm),
Ed25519, and JWS (JSON Web Signature) bodies. Headers can contain a single
signature or several structured signatures. The [verification guide](documentation/tutorials/verify-any-sender.md)
explains encodings, signed input, timestamps, rotation, and custom callbacks.
ash_hooks includes no vendor-specific verifiers; use the sender's signing documentation.

### Receive with AshHooks.Plug

Configure the raw-body reader in your Phoenix endpoint before the router. This
fragment is tested inside a complete endpoint and router with a real SQLite ledger.

<!-- tested: readme-install-endpoint -->
```elixir
plug Plug.Parsers,
  parsers: [:json],
  pass: ["*/*"],
  body_reader: {AshHooks.BodyReader, :read_body, []},
  json_decoder: Phoenix.json_library()
```

`mix igniter.install ash_hooks` attempts to add this reader. Review the result.
Pass `[only: ["/webhooks"]]` as the reader's third element to cache only webhook
routes. An existing body reader can call `AshHooks.BodyReader.put_raw_body/2`
with the complete bytes before parsing. Never reconstruct signed bytes from params.

The following endpoint/router fragments form one tested application example.
Use a fixed source only for a single-tenant ledger without scope fields.

<!-- tested: readme-fixed-source -->
```elixir
# MyAppWeb.Endpoint, before the router
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  json_decoder: Jason,
  body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}

# MyAppWeb.Router
forward "/webhooks/payments", AshHooks.Plug,
  resource: MyApp.WebhookLedger,
  source: :payments,
  request_uri: "https://hooks.example.com"
```

The plug verifies, stores the decoded payload and signed-byte digest, deduplicates,
claims the row under a time-limited ownership token, runs the handler, and records
the result. Configure it outside browser/session/CSRF pipelines. Default responses:

| Outcome | HTTP status |
| --- | --- |
| Terminal row: processed, permanently failed, or superseded | 200 |
| Pending, claimed elsewhere, or retryable row | 500 |
| Invalid signature, stale timestamp, or malformed payload error | 400 |
| Missing secret, paused source, or other ingest failure | 503 |
| Resolver not found or unavailable | 404 or 503 |
| Disallowed method or oversized direct read | 405 or 413 |

Default 503s include `retry-after: 60`; configure `retry_after:` to change it.
POST is the default method. Direct reads allow 8,000,000 bytes by default; preceding
parsers have their own limits. Missing or repeated signature headers yield an
unsigned-request error. With `ingress_tracking :on`, rejected requests may store
one digest row per source, scope, and body, rather than one row per request.

For a scoped or multitenant ledger, use `resolve: {module, function, args}` to
look up a stored endpoint and return `source`, `tenant`, `scope`, and `connection`.
Never trust path strings as tenants or convert them into module names. The scope
keys must match `scope_identity`; include them in the database unique index.

`request_uri:` accepts a configured public base URL or a callback returning the
full public URI. It never trusts the connection's internal host, scheme, or port.
A provider reading `ctx.signature` needs `signature_header:` on the plug or resolver.
Configured providers read their own headers and need no such option.

Provider `handshake/1` can answer challenges before method and signature checks.
Response precedence is provider `response/1`, then the plug's `respond:` callback,
then `AshHooks.Plug.default_response/2`. A `refuse:` callback can customize refusal
headers and body while preserving the status and required headers.

### Handling and identity

Configured providers return a `:webhook` event. Override `parse_event_type/1`
and `handle_event/2` to run application actions. Use a fixed event-name table;
never turn request data into new atoms. Return `{:ok, result}`,
`{:error, :retry, reason}`, or `{:error, :permanent, reason}`. Exceptions, exits,
and throws are contained and recorded as retryable failures with error class
`"handler_crashed"`.

Handlers run at least once. A crash after a business effect and before recording
success can repeat the handler. Make the business effect idempotent, keyed on the
logical event identity. Terminal rows are never processed again.

An explicit `event_id` extractor takes precedence. Invalid extractor results use
the raw-body digest. Otherwise `event_identity/1` is used when implemented; invalid
provider identities fail ingestion. With neither callback, identity is the SHA-256
of the raw body. JWS providers hash canonical JSON of the verified payload.

JSON is the default. `body_format :form` opts a route into flat URL-encoded form
decoding. Verification always sees exact raw bytes first. `previous_secret` allows
both inbound keys until you remove it; `paused` refuses ingestion before verification.
`AshHooks.Ingress.list/2` and `counts/2` expose inbound state.

For HTTP Message Signatures (RFC 9421), use RequestSeal with
`{:request_seal, "~> 1.0"}`. Its adapter integrates verification with a provider.
Configure a nonce replay store when signatures must be accepted only once; ledger
deduplication alone is a different guarantee. See the [verification guide](documentation/tutorials/verify-any-sender.md#http-message-signatures-rfc-9421-with-requestseal).

## Sending webhooks

Declare an outbound event, endpoint resource, subscription resource, and delivery
resource. Dispatch stores exact payload bytes once per endpoint and event ID.
Without an enqueue callback, deliveries stay pending. The tutorial shows a generated
worker; set `oban:` to the supervised instance name or omit it for the default `Oban`.

Delivery succeeds on 2xx, retries 408/429/5xx and transport failures, refuses
redirects, and permanently fails other client errors. Retry-After is bounded;
otherwise retries use exponential backoff with random delay. A 410 stores a
pending disable obligation, conditionally disables the matching endpoint
configuration, and completes the delivery. Subscribe to disable telemetry so
operators can act. A hostname that stops resolving retries as `nxdomain` or
`resolve_timeout`; a validated private or loopback address fails permanently.

The delivery row controls retry counts and timing. Oban provides a durable trigger.
Set all budgets to positive integers. Compilation checks positive integer attempt,
finalization, delivery-attempt, backoff, and Retry-After budgets, backoff ordering,
timeout relationships, and the Oban attempt ceiling. Runtime settings are validated before
delivery; invalid settings fail the job without changing the row.

Schedule `AshHooks.reconcile_pending/3` per declaration and tenant with the same
queue callback used at dispatch. It recovers enqueue gaps, due retries, expired
send leases, and pending disables while preserving retry timing and attempt counts.
Anonymous callbacks need a stable `enqueue_key` for recovery. Synchronize node
clocks because leases use application UTC time. Network delivery remains at least
once; receivers deduplicate using the stable `webhook-id`.

### Optional outbound features

- `retryable_statuses` replaces the ordinary retry set. Success, redirects, and
  the 410 rule stay fixed. `delivery_headers` adds checked metadata headers;
  signing, content type, and framing headers cannot be overridden.
- `certificate_pin` adds a certificate or public-key digest check to HTTPS using
  the bounded adapter. `AshHooks.DestinationPolicy` can allow or deny destinations.
  `AshHooks.Transport` supplies another transport with the same signing and retries.
  Its resolver returns `nil` for HTTP or a transport module exporting `request/5`.
  A raise, throw, exit, or invalid return refuses the attempt with a retryable
  `transport_resolution` failure, without falling back to HTTP.
- `AshHooks.OutboundAttempt` records attempt history, including the real request
  duration and signing-key reference for HTTP 410 responses. History-write failures emit telemetry without
  undoing the delivery's completed result transition.
- Response snippets contain status and content-type summaries by default. Endpoint
  opt-in captures bounded, redacted history bodies. A direct diagnostic run with
  `snippet_capture: true` can capture on the delivery row. For retryable failures,
  wait until due; for terminal rows, call `resend/2` before running again.
- `test_send/2` sends outside subscriptions, using `:signing_mode` (default
  `:standard`). `resend/2` re-arms terminal deliveries. Bulk replay counts a limited
  batch in dry run; repeated calls can select skipped rows again and return no cursor.
- `:standard` signing uses `secret_ref`. `:legacy` and `:dual` also need
  `legacy_secret_ref`. References resolve through your secret store.
- With `key_lifecycle :on`, key rolling keeps both standard keys signing
  before `previous_secret_retired_at`; the previous key stops at that instant
  even if the sweep is delayed. Schedule `AshHooks.Endpoint.expire_previous_secrets/2`
  to remove expired references. An undated previous reference keeps signing,
  is skipped by the sweep, and refuses rolling until
  `AshHooks.Endpoint.schedule_previous_retirement/3` sets its deadline or
  `AshHooks.Endpoint.expire_previous_secret/2` removes it. Without lifecycle
  tracking, previous keys sign until their references are removed.
- A second roll during an active standard key overlap returns
  `{:error, :overlap_active}`. Call `AshHooks.Endpoint.expire_previous_secret/2`
  before rolling again immediately, or wait for the window to end; an ended
  window permits rolling before the sweep. `:overlap_seconds` must be a
  non-negative integer (`{:error, :invalid_overlap}` otherwise); zero stops
  the old key signing at the roll instant. The `endpoint` DSL options
  `default_overlap_seconds` and `max_overlap_seconds` configure the default
  (86,400 seconds when unset) and an optional positive cap. Compilation
  refuses a cap below the effective default. Rolling or scheduling retirement
  beyond the cap from now returns `{:error, {:overlap_exceeds_max, max}}`.
- Endpoint health uses recorded durations, including failed attempts. Eventual
  successes include first-attempt successes. Explicit time bounds need `:from`.
  Supplying `:to` without `:from` returns `{:error, :from_required}`. Health sweeps
  enforce `warning_interval_seconds` (default 60) from the stored warning time,
  including overlapping sweeps. Counts and telemetry confirm successful writes.
- Catalog metadata and payload versions describe events. Subscription attribute
  filters match event metadata. An event log preserves events even with no enabled
  endpoints. Replay takes `declaration: {Emitter, :event_name}` and binds each new
  delivery to that declaration and enqueue callback. Enable `resend_tracking :on`
  to store the requester and request time. Enqueue receives `(delivery, event)`,
  matching the generated worker and recovery contracts. Terminal replay forwards
  the tenant to resend.

## Fitting the extensions to your domain

`payload_attribute` renames a ledger's byte column. `prune_action :none` prevents
injection of the `:prune` destroy action; it leaves application-defined destroy
actions intact. Endpoint status mapping can use an existing enable switch.
Subscription event types may be constrained atoms or strings; both match the same
names. An application declaration replaces the generated attribute and its defaults.

Ledger state transitions use the complete primary key, including custom or
composite keys. Paginated queries additionally require an `:id` attribute. Endpoint
and subscription references require a single UUID-compatible key, including UUIDv7.
A full last page still carries a cursor; a shorter page carries nil.

## Multi-tenancy

Declare consistent attribute multitenancy on every enabled resource, including
attempt history and the event log. Pass the tenant to every entry point and include
the tenant in unique indexes. `AshHooks.Tenancy.resolve/2` validates only the modules
supplied by each caller. Entry points include every resource they touch, including
optional history and event logs, and reject mismatches before data access.

The generated worker carries the tenant in job args. String tenants are supported;
custom parsing must have a matching `tenant_from_attribute` inverse. Tenant-aware
secret resolvers receive both reference and tenant. When adopting tenancy on populated
tables, backfill every tenant value, rebuild identities, and only then enable tenant
traffic. The [checklist](documentation/tutorials/tenancy-adoption-checklist.md) gives
the ordered transition for every tenant.

## Retention and security

Your application schedules retention and controls read access. Inbound pruning
deletes `:processed`, `:failed_permanent`, and `:superseded` rows; it excludes tracked
`:failed_verification` rows, which need a separate policy. Delivery pruning deletes
terminal deliveries and their history in one transaction when `attempts:` is
provided. History-deletion errors roll back the batch and are returned. Both
resources must support transactions; for SQLite, enable `write_transactions?/0`
on the repo. Add `inserted_at` and a matching migration. Deletion reopens deduplication
identities, so retain rows beyond the sender's replay period.

HMAC comparisons use constant time after a length check; public-key verification
uses OTP cryptographic functions. Destination checks defend against server-side
request forgery. Default adapters connect to validated addresses, and the bounded
adapter limits reads and elapsed time. Built-in capture redaction recognizes specific
secret patterns; add rules for application-sensitive values.

The package injects machine write actions and no read policies. Restrict exposed
actions and define read policies for payload-bearing resources. Internal operations
bypass authorization and must only be called by trusted application code. Report
vulnerabilities privately through [SECURITY.md](SECURITY.md).

## Observability and stability

`AshHooks.Telemetry` lists all event names and metadata. Attach exact names using
`attach_many`; events omit payloads, bodies, and signing secrets. The tutorial's
handler shows the basic lifecycle; the module reference includes optional events.

The public contract includes the DSL, public functions, injected attributes and
actions, telemetry, and error classes. Breaking changes next ship in 4.0.0;
deprecations run at least two minor releases. Safety corrections can change defective
behavior in patch releases and are described in the [CHANGELOG](CHANGELOG.md).
Development supports macOS and Linux; use WSL2 on Windows.

Upgrading from before 3.0.0 removes built-in vendor providers and requires explicit
providers. [UPGRADING.md](UPGRADING.md) explains names, identities, schemas, and versions.
See [CONTRIBUTING.md](CONTRIBUTING.md), the [DSL reference](documentation/dsls/DSL-AshHooks.md),
and the [API reference](https://hexdocs.pm/ash_hooks) for more.

## License

MIT.
