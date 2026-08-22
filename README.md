# AshHooks

[![Hex.pm](https://img.shields.io/hexpm/v/ash_hooks.svg)](https://hex.pm/packages/ash_hooks)
[![CI](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml/badge.svg)](https://github.com/baselabs/ash_hooks/actions/workflows/ci.yml)

Webhooks for [Ash Framework](https://ash-hq.org), in both directions:

- **Inbound** — receive provider webhooks, verify their signatures,
  deduplicate them on a ledger (a table recording every delivery — the
  dedup record itself), and run your handler once per delivery.
- **Outbound** — sign and deliver your own webhooks with retries,
  backoff, and dead-lettering, on any queue backed by Oban.

The two halves work independently: if you only receive webhooks, you
need no queue infrastructure at all.

- Verify signatures for [ComplyCube](https://docs.complycube.com/) and
  [HubSpot v3](https://developers.hubspot.com/) out of the box; bring
  your own scheme with a one-module provider behaviour.
- Duplicate and replayed deliveries process exactly once on the ledger;
  crashes mid-flight resume on redelivery instead of losing events.
- Outbound webhooks follow the [Standard Webhooks](https://www.standardwebhooks.com)
  spec, so receivers verify with any conformant library. Key rotation
  and a legacy-envelope mode for receivers mid-migration are built in.
- Retries honor `Retry-After`, back off with jitter, dead-letter at a
  ceiling, and durably disable endpoints that return 410.
- Safe defaults: secrets are only ever resolved through your callbacks
  (literal secrets are rejected at compile time), endpoint URLs are
  checked against server-side request forgery (SSRF — a registered
  webhook URL can't be made to hit your internal network) at
  registration and again at send time, and response
  bodies are never stored unless you explicitly opt in for a diagnostic
  run. The ledgers store raw payloads, and read access to them is yours
  to govern — the package injects no read policies (see
  [Security](#security)).
- Telemetry events for the whole send/receive lifecycle — structured so
  they can never leak secrets or payloads into your metrics backend.

Requires Elixir ~> 1.17 (OTP 27+) and Ash ~> 3.0. Oban (~> 2.20) is needed only
for outbound delivery; Phoenix or Plug only for receiving. From 1.0
the package follows semantic versioning with a named public surface —
see [Stability](#stability).

## Installation

```elixir
def deps do
  [
    {:ash_hooks, "~> 1.0"},
    # only for outbound delivery:
    {:oban, "~> 2.20"}
  ]
end
```

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
`{:app_env, path}`, or a zero-arity function — never literal values.

Your provider module also defines the handler — the `handle_event/2`
callback that receives the verified payload (the tutorial shows one
from scratch).

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
  {:ok, :created, %{status: :processed}} -> send_resp(conn, 200, "")
  {:ok, :created, _} -> send_resp(conn, 500, "")   # handler failed
  {:ok, :duplicate, _} -> send_resp(conn, 200, "") # already seen
  {:error, _} -> send_resp(conn, 400, "")          # bad signature/payload
end
```

**Delivery semantics.** A delivery that finished (`:processed` or
`:failed_permanent`) is never processed again. A crash after your
handler ran but before the ledger recorded it will re-run the handler
on redelivery — so write handlers idempotent, keyed on the provider's
event id. In short: durable deduplication, at-least-once handler
invocation.

HubSpot's v3 scheme also signs the HTTP method and the full request
URI, so its controller passes both — build the *public* URI from a base
URL you configure, not from `conn`, which behind a TLS proxy carries
the internal host and port.

`claim_delivery/2`, `mark_processed/3`, and friends are public if you
want to drive the lease machine from your own async pipeline;
`AshHooks.Ingress.reap/1` re-drives deliveries whose claims died with
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
{:ok, event} = AshHooks.Event.new(type: :order_paid, payload: Jason.encode!(order))

AshHooks.dispatch(Order, :order_paid, event,
  enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}
)
```

Every matching enabled endpoint gets a durable delivery row carrying
the exact bytes to sign. The worker signs per Standard Webhooks (the
same `webhook-id` on every retry), succeeds only on 2xx, never follows
redirects, honors `Retry-After` (bounded), backs off with jitter on
5xx and transport errors, dead-letters other client errors, and
durably disables the endpoint on 410. An endpoint's failure never
blocks delivery to its siblings.

**Without Oban**, dispatch still works — every matching endpoint gets a
durable `:pending` row — but nothing drives those rows until you define
the worker (or call `AshHooks.Delivery.run/2` yourself): the delivery
row owns the retry policy, and the queue is only its trigger
([ADR-0008](https://github.com/baselabs/ash_hooks/blob/main/docs/adr/0008-delivery-row-owns-retry-policy-oban-is-the-trigger.md)).

The default HTTP adapter is a small native client with every read
capped, so a hostile response can't balloon worker memory; OTP's
`:httpc` is available as an alternative, and you can inject your own
adapter for tests or proxies.

**Response bodies are never stored** — each delivery row keeps the
status and a content-type summary. When debugging a misbehaving
endpoint, re-drive its row with body capture enabled and the captured
body is stored only after passing the package's built-in redaction
(homoglyph folding, decode-chain analysis, entropy checks — encoded
secrets don't survive it), marked `[captured]` in the snippet:

```elixir
# diagnostic: one row, one capture, floor-redacted
AshHooks.Delivery.run(row, snippet_capture: true)
```

For a domain-specific denylist, also pass a `snippet_redactor`
(`{module, function}` or `fn body -> {:ok, body} | {:error, term}`)
— it runs before the built-in redaction, and a failing redactor
leaves the body uncaptured; see `AshHooks.Worker` for the
worker-macro form.

**Signing modes.** `:standard` (default) needs only the endpoint's
`secret_ref`. `:dual` and `:legacy` additionally require a
`legacy_secret_ref` — `:dual` emits both envelopes so receivers can
migrate, `:legacy` emits only the old one.

## Observability

Attach one handler to see the whole lifecycle — inbound
verify/dedup/claim, enqueue failures, delivery
attempt/result/backoff/dead-letter/endpoint-disable. Events carry ids,
integers, fixed atoms, and classified reasons — never secrets, bodies,
or payloads. The exact event list and a copy-paste `attach_many` block
are in the `AshHooks.Telemetry` docs and the
[get-started tutorial](https://github.com/baselabs/ash_hooks/blob/main/documentation/tutorials/get-started.md).

## Retention

Ledger and delivery rows accumulate by default (they ARE the dedup and
audit record). When you want them bounded, drive the retention hooks on
a schedule of your choosing (an Oban cron job, a mix task, a nightly
job):

- `AshHooks.Ingress.prune/2` and `AshHooks.Delivery.prune/2` delete
  TERMINAL rows older than a cutoff — retryable and in-flight rows are
  never touched. They key off the resource's `inserted_at`, so add
  Ash's `timestamps()` to the resource and its migration.
- `AshHooks.Ingress.redact_payload/4` rewrites a claimed row's payload
  under the claim fence (scrub sensitive fields while keeping the dedup
  identity; the original-bytes digest is preserved for audit).

Deleting a terminal row re-opens its dedup identity — a replayed
webhook re-processes, a re-emitted outbound event re-sends — so set the
TTL beyond any replay or re-emission horizon.

## Security

The package enforces the guarantees it owns: constant-time signature
compares, compile-time rejection of literal secrets, SSRF (server-side
request forgery) checks at registration and send time (DNS-rebinding closed by connecting to the
validated address), memory-capped HTTP reads, and redaction-gated
response capture.

Read access is the one floor the package deliberately does **not**
enforce, because it cannot know your actors: the ledger and delivery
resources are YOUR resources in YOUR domain, and the package injects no
policies — reads are governed entirely by the policies you write.
These rows carry raw provider payloads (third-party PII), event ids,
and scope keys. Mount them behind policies that deny reads by default:

```elixir
policies do
  # deny by default; open exactly what your app needs
  policy action_type(:read) do
    authorize_if actor_attribute_equals(:admin, true)
  end
end
```

(This assumes `Ash.Policy.Authorizer` in the resource's `authorizers`;
match the snippet to your actual actors. The `policies` block lives
inside the ledger/delivery resource module (with
`authorizers: [Ash.Policy.Authorizer]` in the `use Ash.Resource`
options — Ash's [policies guide](https://hexdocs.pm/ash/policies.html)
covers the full model). Vulnerability reports:
[SECURITY.md](SECURITY.md) — never a public issue.

## Stability

From 1.0.0, ash_hooks follows semantic versioning over a named public
surface (the DSL, the public modules, injected attributes/actions,
telemetry events, error classes) — breaking changes only in 2.0,
deprecations run two minors minimum, safety corrections ship as fixes
([ADR-0010](https://github.com/baselabs/ash_hooks/blob/main/docs/adr/0010-semver-and-support-policy.md)).

Minimum supported versions, each CI-tested: Elixir ~> 1.17 (OTP 27+),
Ash ~> 3.0, Oban ~> 2.20 (optional, outbound only). One nuance: a fix
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
