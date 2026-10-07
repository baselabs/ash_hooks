# AshHooks

[![Hex.pm](https://img.shields.io/hexpm/v/ash_hooks.svg)](https://hex.pm/packages/ash_hooks)
[![CI](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml)

Webhooks for [Ash Framework](https://ash-hq.org), in both directions:

- **Inbound** — receive provider webhooks, verify their signatures,
  deduplicate them on a ledger (a table recording every delivery — the
  dedup record itself), and run your handler with durable deduplication
  and at-least-once processing.
- **Outbound** — sign and deliver your own webhooks with retries,
  backoff, and dead-lettering through Oban or your own scheduler.

The two halves work independently: if you only receive webhooks, you
need no queue infrastructure at all.

- Verify signatures for [ComplyCube](https://docs.complycube.com/) and
  [HubSpot v3](https://developers.hubspot.com/) out of the box; bring
  your own scheme with a one-module provider behavior.
- Duplicate and replayed deliveries are deduplicated on the ledger —
  exactly one row per delivery; crashes mid-flight resume on
  redelivery instead of losing events (handlers run at-least-once).
- Outbound webhooks follow the [Standard Webhooks](https://www.standardwebhooks.com)
  spec, so receivers verify with any conformant library. Key rotation
  and a legacy-envelope mode for receivers mid-migration are built in.
- Retries honor `Retry-After`, back off with jitter, dead-letter at a
  ceiling, and durably disable endpoints that return 410.
- Safe defaults: inbound declarations use secret resolvers rather than literal
  binaries, and endpoint rows store secret references. Endpoint URLs are
  checked against server-side request forgery (SSRF) at
  registration and again at send time, and response
  bodies are never stored unless you explicitly opt in for a diagnostic
  run. Inbound ledgers retain decoded payloads and a digest of the signed
  bytes; outbound ledgers retain the exact bytes to send. Read access is yours
  to govern — the package injects no read policies (see
  [Security](#security)).
- Telemetry events for the whole send/receive lifecycle, with classified
  reasons and identifiers rather than bodies or signing secrets.

Requires Elixir ~> 1.20 (OTP 28+) and Ash >= 3.34.3, < 4.0. Add Oban (~> 2.20)
for the generated delivery worker, and Phoenix or Plug for the HTTP ingress.
Direct delivery and signature verification work without either dependency. From 1.0
the package follows semantic versioning with a named public surface —
see [Stability](#stability).

## Installation

```elixir
def deps do
  [
    {:ash_hooks, "~> 2.0"},
    # only for outbound delivery:
    {:oban, "~> 2.20"}
  ]
end
```

Upgrading from 1.x? Follow [UPGRADING.md](UPGRADING.md) before starting 2.0
workers. The delivery schema and HubSpot's default dedup identity have changed.

Or `mix igniter.install ash_hooks`, which also tries to patch your
endpoint's `Plug.Parsers` with a raw-body reader. Signature schemes
sign the exact wire bytes, and a router plug cannot recover what the
parser already consumed — so if the automatic patch didn't apply, add
it yourself:

```elixir
plug Plug.Parsers,
  parsers: [:json],
  pass: ["*/*"],
  body_reader: {AshHooks.BodyReader, :read_body, []},
  json_decoder: Phoenix.json_library()
```

By default every parsed request carries a cached copy of its raw body;
pass `[only: ["/webhooks"]]` as the reader's third element to limit
that memory cost to your webhook routes.

You also create your own tables — ash_hooks injects fields and
identities onto your resources, and your migrations carry them,
including the unique indexes the deduplication guarantee rests on.
Complete, runnable migrations, resources, and setup are in the
[get-started tutorial](https://github.com/baselabs/ash_hooks/blob/main/documentation/tutorials/get-started.md).

## Receiving webhooks

Declare an inbound source on a ledger resource:

```elixir
use Ash.Resource,
  data_layer: AshPostgres.DataLayer,
  extensions: [AshHooks, AshHooks.InboundDelivery]

inbound_delivery do
  # provider event ids aren't unique across accounts — your scope slots
  # extend the dedup identity (each must be a non-nullable attribute)
  scope_identity([:account_id])
end

attributes do
  attribute(:account_id, :string, allow_nil?: false)
end

webhooks do
  inbound :comply_cube do
    secret {:app_env, [:my_app, :complycube_secret]}
  end
end
```

Secrets are always sources — an `{m, f, a}` callback, an
`{:app_env, path}`, a zero-arity function, or (multi-tenant apps) a
one-arity function that receives the tenant — never literal values.

Your provider module also defines the handler — the `handle_event/2`
callback that receives the verified payload (the
[guided-tour Livebook](https://github.com/baselabs/ash_hooks/blob/main/documentation/livebooks/get-started.livemd)
builds one from scratch in a few lines).

From your controller, one call runs the whole pipeline: verify the
signature over the raw bytes, persist the payload, deduplicate, claim
under a lease (a time-limited ownership claim — rows whose worker died
are reclaimed when it expires), run your handler, and record the
outcome.

```elixir
case AshHooks.Ingress.ingest(Ledger, :comply_cube, conn.private[:ash_hooks_raw_body], %{
       signature: List.first(get_req_header(conn, "complycube-signature")),
       headers: Map.new(conn.req_headers),
       scope: %{"account_id" => conn.params["account_id"]}
     }) do
  # Acknowledge terminal rows, including permanent failures.
  # A duplicate may have retried its handler: inspect its current status.
  {:ok, _tag, %{status: status}} when status in [:processed, :failed_permanent, :superseded] ->
    send_resp(conn, 200, "")
  {:ok, _tag, _row} -> send_resp(conn, 500, "")    # handler failed
  {:error, _} -> send_resp(conn, 400, "")          # bad signature/payload
end
```

**Delivery semantics.** A terminal delivery (`:processed`,
`:failed_permanent`, or `:superseded`) is never processed again. A crash after your
handler ran but before the ledger recorded it will re-run the handler
on redelivery — so write handlers idempotent, keyed on the logical event
or batch identity (for action-level idempotency elsewhere in your app, our
sibling package
[`ash_onetime`](https://hex.pm/packages/ash_onetime) is an optional
companion). Permanent failures belong on your operator surface; the successful
acknowledgment prevents a provider from retrying a row that cannot run again.

HubSpot's v3 scheme also signs the HTTP method and the full request
URI, so its controller passes both — build the *public* URI from a base
URL you configure, not from `conn`, which behind a TLS proxy carries
the internal host and port.

`claim_delivery/3`, `mark_processed/4`, and friends are public if you
want to drive the lease machine from your own async pipeline;
`AshHooks.Ingress.reap/2` re-drives deliveries whose claims died with
an expired lease.

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

The secret resolver maps an endpoint's secret reference to its value —
generate values with `AshHooks.Signing.generate_secret/0`, store them
whole in your secret store, and return them unchanged.

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

**Without Oban**, dispatch still works — every matching endpoint gets a
durable `:pending` row — but nothing drives those rows until you define
the worker (or call `AshHooks.Delivery.run/2` yourself): the delivery
row owns the retry policy, and the queue is only its trigger
([ADR-0008](https://github.com/baselabs/ash_hooks/blob/main/docs/adr/0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md)).

The default HTTP adapter bounds response headers, retained body bytes, and
the complete operation time. OTP's `:httpc` is an alternative with additional
buffering limits described in its module docs. You can also provide an adapter
for your application's transport requirements.

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

**Response bodies are never stored by default** — each delivery row keeps the
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

Only non-terminal rows are driven — a row that already finished will
not re-send; re-drive a failed one, or wait for its retry.

For a domain-specific denylist, also pass a `snippet_redactor`
(`{module, function}` or `fn body -> body | nil` — return the
redacted binary, or nil to leave the body uncaptured). It runs before
the built-in redaction; a crashing redactor leaves the body
uncaptured. See `AshHooks.Worker` for the worker-macro form.

**Signing modes.** `:standard` (default) needs only the endpoint's
`secret_ref`. `:dual` and `:legacy` additionally require a
`legacy_secret_ref` — `:dual` emits both envelopes so receivers can
migrate, `:legacy` emits only the old one.

## Fitting the extensions to your domain

The injected fields and actions carry opinionated names by default;
your domain may reserve those names or own the lifecycle itself.
Every knob is a per-resource DSL option, fail-closed at compile:

```elixir
# your domain reserves `payload` for its own sole payload store —
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

# your register already has an enable switch — map the durable
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
(your constraints, your default — matching handles atoms and strings
identically, wildcard included), and injected-PK ledgers still classify
`:created`/`:duplicate` exactly.

**Policies.** The package injects write actions, not the authorization
around them. Cover the generated machine actions with an action-specific
policy of your own (the runtime's internal calls bypass policies by
design), or keep the resources off every actor-facing surface — the
full action set and obligation are stated at each extension site in the module docs.

## Observability

Attach one handler to see the whole lifecycle — inbound
verify/dedup/claim, enqueue failures, delivery
attempt/result/backoff/dead-letter/endpoint-disable. Events carry ids,
integers, fixed atoms, and classified reasons — never secrets, bodies,
or payloads. The exact event list and a copy-paste `attach_many` block
are in the `AshHooks.Telemetry` docs and the
[get-started tutorial](https://github.com/baselabs/ash_hooks/blob/main/documentation/tutorials/get-started.md).

## Retention

Ledger and delivery rows accumulate by default (they are the dedup and
audit record). When you want them bounded, drive the retention hooks on
a schedule of your choosing (an Oban cron job, a mix task, a nightly
job):

- `AshHooks.Ingress.prune/2` and `AshHooks.Delivery.prune/2` delete
  terminal rows older than a cutoff — retryable and in-flight rows are
  never touched. They key off the resource's `inserted_at`, so add
  Ash's `timestamps()` to the resource and its migration. Append-only
  ledgers may omit the destroy action entirely
  (`prune_action :none`) — `prune/2` then fails loud with a named
  error, and deletion is your own surface.
- `AshHooks.Ingress.redact_payload/5` rewrites a claimed row's payload
  under the claim fence (scrub sensitive fields while keeping the dedup
  identity; the original-bytes digest is preserved for audit).

Deleting a terminal row re-opens its dedup identity — a replayed
webhook re-processes, a re-emitted outbound event re-sends — so set the
TTL beyond any replay or re-emission horizon.

## Multi-tenancy

If one app serves multiple organizations, ash_hooks works the way Ash
does: declare **attribute multitenancy** on the four resources — your
Subscription, Endpoint, inbound ledger, and outbound delivery ledger —
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
AshHooks.Ingress.ingest(WebhookLedger, :stripe, raw_body, %{
  signature: sig,
  tenant: org.id
})
```

From there the isolation is structural, not advisory: a dispatch for
tenant A cannot create a delivery row for tenant B's endpoint, a
subscription pointing at another tenant's endpoint id resolves to
not-found and is skipped, the inbound dedup identity is per-tenant, and
the claim fence and every mark are per-tenant. Touch a multitenant
resource without a tenant and you get `{:error, :tenant_required}`
before any data access; mix tenancy declarations across the resources
one operation touches (say, a tenant-scoped delivery ledger beside an
undeclared endpoint table) and you get `{:error, :tenancy_mismatch}` —
both named errors, both fail-closed. Each operation checks the set it
actually reads: an inbound-only app declares tenancy on its ledger
alone and needs none of the outbound resources.

The async path carries its own weight: the Oban job args include the
row's tenant (the worker recovers full context after any restart), the
retention sweeps take a `:tenant` (with `AshHooks.reap_all/2` /
`AshHooks.prune_all/2` sugar to sweep a tenant list), and
`AshHooks.reconcile_pending/3` repairs rows stranded between the row
write and the enqueue — per tenant, with single-winner semantics. If
your signing secrets are per-tenant, resolution can be too: the worker
macro's `tenant_aware_secrets: true` (the resolver becomes
`f(ref, tenant)`), an inbound `secret fn tenant -> {:ok, secret} end`,
and an optional provider `webhook_signing_secret(connection, tenant)`
callback.

Single-tenant app? Do none of this. No tenant passed means no tenant
threaded — behavior is identical.

Adopting tenancy on tables that already have rows is an ordered
transition (backfill, then regenerate indexes, then enable) — the
[adoption checklist](https://github.com/baselabs/ash_hooks/blob/main/documentation/tutorials/tenancy-adoption-checklist.md)
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
options — Ash's [policies guide](https://hexdocs.pm/ash/policies.html)
covers the full model). Vulnerability reports:
[SECURITY.md](SECURITY.md) — never a public issue.

## Stability

ash_hooks follows semantic versioning over a named public
surface (the DSL, the public modules, injected attributes/actions,
telemetry events, error classes) — the current major is 2; breaking changes next ship in 3.0,
deprecations run two minors minimum, safety corrections ship as fixes
([ADR-0010](https://github.com/baselabs/ash_hooks/blob/main/docs/adr/0010-semver-and-support-policy.md)).

Minimum supported versions: Elixir ~> 1.20 (OTP 28+; CI-tested on
Erlang/OTP 28 and 29), Ash >= 3.34.3 and < 4.0, Oban ~> 2.20 (optional, outbound only).
Development is supported on macOS and Linux; Windows developers use WSL2.
CI runs on Linux, including an AshPostgres leg exercising a
`uuid_v7`-keyed consumer shape. On Ash 3.33+ your
application must also set Ash's required `default_string_length_count`
config — an Ash requirement for every app compiling resources, not an
ash_hooks one ([UPGRADING.md](UPGRADING.md)). One nuance: a fix
that closes a safety hole can change behavior in a patch release (a
delivery that wrongly succeeded may now retry, for example) — such
corrections are always called out under "Fixed" in the
[CHANGELOG](CHANGELOG.md). Moving off a supported version is a minor
release with an [UPGRADING.md](UPGRADING.md) note.

## Further reading

- [Get started](https://github.com/baselabs/ash_hooks/blob/main/documentation/tutorials/get-started.md) —
  complete walkthrough, migrations included
- [Guided tour (Livebook)](https://github.com/baselabs/ash_hooks/blob/main/documentation/livebooks/get-started.livemd) —
  run the whole library inside one notebook
- [UPGRADING.md](UPGRADING.md) — migration notes per release
- [SECURITY.md](SECURITY.md) — reporting and scope
- [DSL reference](https://github.com/baselabs/ash_hooks/tree/main/documentation/dsls)
- [Architecture decisions](https://github.com/baselabs/ash_hooks/tree/main/docs/adr)
  (ADRs — the reasoning behind every major design choice)
- [CONTRIBUTING.md](CONTRIBUTING.md) — setup, the gate suite, how to
  propose changes; GitHub issues are the support channel
- Full API docs at [hexdocs.pm/ash_hooks](https://hexdocs.pm/ash_hooks)

## License

MIT.
