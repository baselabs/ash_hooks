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
    }, authorize?: false)

{:ok, _subscription} =
  Ash.create(
    MyApp.WebhookSubscription,
    %{
      endpoint_id: endpoint.id,
      event_types: ["order_paid"],
      event_filters: %{"region" => ["us", "ca"]}
    }, authorize?: false)

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

All filter keys must be declared and match. A list value matches any member;
unknown keys fail closed. Metadata keys are strings. Metadata is unsigned context, not part of the wire
payload. The event log retains the original current-version bytes even when a
filter excludes every endpoint. Delivery rows retain the selected variant.

No pin, or a pin to version 2, uses the original bytes. An unsupported pin fails
that endpoint with `:unknown_pinned_version` before a delivery is written. A
builder error, exception, or nonbinary result fails with `:variant_failed`.
Repair the pin or builder and dispatch the same event ID again; existing rows
keep their original bytes. Do not delete delivery history to negotiate a version.
See [delivery operations](outbound-operations.md) for sends, health, and recovery.
