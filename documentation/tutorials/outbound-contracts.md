# Catalogs, payload versions, and subscription filters

Continue the application from [get started](get-started.md) and
[event recovery](outbound-recovery.md). Catalog metadata describes events;
version pins select exact bytes; filters choose which subscriptions participate.
None of these features changes the event's stable identity.

## Declare versions and filterable metadata

Add this section to `MyApp.WebhookEndpoint`:

<!-- tested: contracts-endpoint-options -->
```elixir
endpoint do
  version_pinning :on
end
```

Add `filter_attributes` to the existing `MyApp.WebhookSubscription` section:

<!-- tested: contracts-subscription-options -->
```elixir
subscription do
  endpoint_resource MyApp.WebhookEndpoint
  filter_attributes [:region]
end
```

Add a payload builder. It receives the original event and returns serialized
bytes. Keep old builders available while any endpoint pins that version.

<!-- tested: contracts-payload-builder -->
```elixir
defmodule MyApp.PayloadVersions do
  def order_paid_v1(event) do
    with {:ok, payload} <- Jason.decode(event.payload) do
      {:ok, Jason.encode!(%{order_id: payload["order_id"]})}
    end
  end
end
```

Replace `MyApp.Order`'s `webhooks` section with:

<!-- tested: contracts-outbound-options -->
```elixir
webhooks do
  outbound :order_paid do
    subscriptions MyApp.WebhookSubscription
    deliveries MyApp.OutboundDelivery
    events MyApp.OutboundEvent
    description "An order reached the paid state."
    payload_schema %{"type" => "object", "required" => ["order_id", "schema_version"]}
    example ~s({"order_id":"order-1","schema_version":2})
    version 2
    payload_versions %{1 => {MyApp.PayloadVersions, :order_paid_v1}}
  end
end
```

Migrate both optional columns before deploying those declarations:

<!-- tested: contracts-migration -->
```elixir
alter table(:webhook_endpoints) do
  add :pinned_payload_version, :integer
end

alter table(:webhook_subscriptions) do
  add :event_filters, :map
end
```

## Build a picker and dispatch matching payloads

`Catalog.entries/1` and `entry/2` expose declarations without reading delivery
payloads. `payload_schema` is metadata for your tooling; it does not validate
payloads at dispatch. Validate application data before serializing it.

Run this in a fresh tutorial database. Set `PUBLIC_WEBHOOK_TEST_URL` to a receiver
you control and store a generated signing secret in `OUTBOUND_WEBHOOK_SECRET`
for the resolver from get started. The URL must be safe for the chosen transport.

<!-- tested: contracts-dispatch -->
```elixir
{:ok, [catalog_entry]} = AshHooks.Catalog.entries(MyApp.Order)
{:ok, ^catalog_entry} = AshHooks.Catalog.entry(MyApp.Order, :order_paid)

{:ok, endpoint} =
  Ash.create(
    MyApp.WebhookEndpoint,
    %{
      url: System.fetch_env!("PUBLIC_WEBHOOK_TEST_URL"),
      secret_ref: "outbound-main",
      pinned_payload_version: 1
    },
    authorize?: false
  )

{:ok, _subscription} =
  Ash.create(
    MyApp.WebhookSubscription,
    %{
      endpoint_id: endpoint.id,
      event_types: ["order_paid"],
      event_filters: %{"region" => ["us", "ca"]}
    },
    authorize?: false
  )

{:ok, event} =
  AshHooks.Event.new(
    id: "msg_contract-order-1",
    type: :order_paid,
    payload: Jason.encode!(%{order_id: "order-1", schema_version: 2}),
    metadata: %{"region" => "us"}
  )

{:ok, [%{status: :deferred}]} = AshHooks.dispatch(MyApp.Order, :order_paid, event)

{:ok, %{records: [delivery]}} =
  AshHooks.Delivery.list(MyApp.OutboundDelivery, endpoint_id: endpoint.id)

%{"order_id" => "order-1"} = Jason.decode!(delivery.payload)

{:ok, excluded} =
  AshHooks.Event.new(
    id: "msg_contract-order-2",
    type: :order_paid,
    payload: event.payload,
    metadata: %{"region" => "eu"}
  )

{:ok, []} = AshHooks.dispatch(MyApp.Order, :order_paid, excluded)
```

All filter keys must name a declared attribute and match. A nonempty list
matches any member. The write check refuses undeclared keys and empty or
improper lists. Metadata keys are strings. Metadata is unsigned context, not
part of the wire payload. The event log retains the original payload bytes
even when a filter excludes every endpoint. Delivery rows retain the selected
variant.

No pin, or a pin to version 2, uses the original bytes. An unsupported pin fails
that endpoint with `:unknown_pinned_version` before a delivery is written. A
builder error, exception, or nonbinary result fails with `:variant_failed`.
Repair the pin or builder and dispatch the same event ID again; existing rows
keep their original bytes. Do not delete delivery history to negotiate a version.
See [delivery operations](outbound-operations.md) for sends, health, and recovery.

## Host signing and exact prepared requests

Declare a module implementing `AshHooks.Signer` with the endpoint's `signer`
option. Its `sign/2` callback receives an `AshHooks.Http.Request` and a context
with `delivery`, `endpoint`, `attempt`, `event_id`, `tenant` and `custody_tenant`.
Native signatures and `delivery_headers` are already present. The callback runs
outside package database phases and inside the common attempt deadline.
Dispatch, generated workers, test sends, resends and replay all use this path.

Return a nonempty ordered list of new header lines and metadata containing
`key_refs` in `{:ok, headers, %{key_refs: refs}}`. Supply one to eight nonempty
UTF-8 references, each at most 255 bytes. Return `:skip` for an endpoint that
uses native signing alone, `{:error, :retry}` for a retryable failure or
`{:error, :terminal}` to dead-letter before transport. Raises, throws, exits,
malformed results, empty headers or references, reserved names and collisions
with existing headers retry as `signer_failed`. Callback contents never enter
stored errors or telemetry. Failed signing records neither request latency nor
key provenance and stamps no native first use.

List every host-owned attribute that determines signing in `signer_attributes`,
including key references and scheme selection. Spark requires real, nonsensitive
attributes whose stored values can be read and compared through their Ash types.
The 410 snapshot records these values; conditional disablement compares typed
values and protects an endpoint if the configuration changed or an old snapshot
omits a declared attribute. Store opaque references rather than key material.

### Host-only endpoints and custody transitions

`native_signing :required` is the default and retains the existing schema and
native key requirement. Set `native_signing :optional` only with a signer and
after relaxing `secret_ref` NOT NULL. The selected delivery mode uses occupied
native slots only. With no native references, native preparation adds only
`webhook-id` and `webhook-timestamp`; the host signer must then sign. A skipped
host signer with no native signature retries as `unsigned`.

An optional-native custody resource can create a host-only endpoint through its
ordinary create action, without issuing a native key. Use
`AshHooks.Endpoint.enable_native_signing/2` to issue and attach a native standard
or legacy slot, with `generate:` or `material:` and explicit `tenant:`. Use
`AshHooks.Endpoint.disable_native_signing/2` to detach all native slots and retire
their custody references for durable disposal through the registry. The host's
attributes remain on the row. Continue the registry sweeper until every retired
reference is destroyed. Re-enabling issues a fresh reference. Run issuance and
mode transitions after any enclosing transaction commits.

Resolve host signing keys under the explicit `tenant`. When the endpoint declares
a custodian, `custody_tenant` is its canonical custody tenant; otherwise it is nil
and the host owns canonicalization. Never resolve a reference globally or borrow
another tenant's key because its reference string matches.

### Adapter obligation

The prepared request carries the uppercase method, original URL, exact escaped
path and query (`/` for an empty path), complete ordered header lines, and exact
body bytes. Authority, connection close, content type and byte content length are
present before signing. Signers append lines; they cannot replace a package or
existing header. Header names are compared case-insensitively for collisions.

`AshHooks.Http` and `AshHooks.Transport` expose optional `send_prepared/2`.
Implementing it promises the exact request line, header lines in the supplied
order and body, with no added headers or framing. Bounded implements this
contract. Httpc does not implement it: raw-listener qualification found that
`:httpc` rewrites percent escapes in the signed target even with `headers_as_is`.
A signer-configured endpoint using
an adapter without that callback dead-letters as `adapter_cannot_send_prepared`
before the signer runs, including when the signer would return `:skip`.

Legacy `request/5` still takes a map. Existing custom adapters continue to serve
endpoints without a host signer. A prepared-capable adapter is selected whenever
available; with every option off, Bounded's prepared and legacy paths send the
same bytes. Redirect, destination validation, TLS and response bounds still apply.

### Signing provenance

After migrating the attempt table's nullable string array, set
`record_signing_provenance :on` in `outbound_attempt`. `signing_key_refs` records
the native slots actually used in signing order, followed by the host signer's
references, on success, transport failure and 410 recovery. The singular
`signing_key_ref` names the current key of the selected native mode, or the first
host reference for host-only signing. Signing telemetry reports duration and a
fixed outcome through `[:ash_hooks, :delivery, :sign]` without callback contents.

New event-log replay rows select the endpoint's matching subscription signing
mode under the same tenant, reading every page of the consumer's primary read
action. Replay skips missing deliveries with no eligible subscription and
reports conflicting matching modes as a per-event error.
