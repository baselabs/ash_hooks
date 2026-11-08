defmodule AshHooks.EventCatalogTest do
  @moduledoc """
  The event catalog: the outbound DSL declares each event type with a
  description, a payload schema, and a version; the catalog reads back for
  event pickers and doc generation; and an endpoint can PIN a payload
  version — a pinned endpoint receives the declared variant's bytes while
  everyone else receives the current version.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventCatalogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("catalog_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end

    endpoint do
      version_pinning(:on)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventCatalogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("catalog_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.EventCatalogTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventCatalogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("catalog_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Variants do
    @moduledoc false
    def order_paid_v1(_event), do: {:ok, Jason.encode!(%{"schema" => "v1"})}
    def broken(_event), do: {:error, :variant_failed}
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventCatalogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("catalog_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.EventCatalogTest.Subscription)
        deliveries(AshHooks.EventCatalogTest.Delivery)

        description("An order reached the paid state.")

        example(~s({"order_id": "ord_123", "amount": 4200}))

        payload_schema(%{
          "type" => "object",
          "required" => ["order_id", "amount"],
          "properties" => %{"order_id" => %{"type" => "string"}}
        })

        version(2)
        payload_versions(%{1 => {AshHooks.EventCatalogTest.Variants, :order_paid_v1}})
      end

      outbound :order_canceled do
        subscriptions(AshHooks.EventCatalogTest.Subscription)
        deliveries(AshHooks.EventCatalogTest.Delivery)

        description("An order was canceled.")

        version(2)
        payload_versions(%{1 => {AshHooks.EventCatalogTest.Variants, :broken}})
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.EventCatalogTest.Endpoint)
      resource(AshHooks.EventCatalogTest.Subscription)
      resource(AshHooks.EventCatalogTest.Delivery)
      resource(AshHooks.EventCatalogTest.Emitter)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo

  @endpoints "catalog_endpoints"
  @subscriptions "catalog_subscriptions"
  @deliveries "catalog_deliveries"
  @emitters "catalog_emitters"

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT, pinned_payload_version INTEGER
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY, event_types TEXT NOT NULL, endpoint_id TEXT NOT NULL, signing_mode TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

    Repo.query!("CREATE TABLE IF NOT EXISTS #{@emitters} (id TEXT PRIMARY KEY)")

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@emitters}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@emitters}")
    :ok
  end

  defp endpoint!(pinned \\ nil) do
    Ash.create!(
      Endpoint,
      %{
        url: "https://hooks.example.test/hook",
        secret_ref: "cat-main",
        pinned_payload_version: pinned
      },
      authorize?: false
    )
  end

  defp subscribe!(endpoint) do
    Ash.create!(
      Subscription,
      %{endpoint_id: endpoint.id, event_types: ["order_paid"]},
      authorize?: false
    )
  end

  defp dispatch!(event) do
    AshHooks.dispatch(Emitter, :order_paid, event)
  end

  test "the catalog reads back the declared metadata for pickers and docs" do
    assert {:ok, entries} = AshHooks.Catalog.entries(Emitter)
    assert length(entries) == 2
    entry = Enum.find(entries, &(&1.name == :order_paid))
    assert entry.description == "An order reached the paid state."
    assert entry.version == 2
    assert entry.payload_schema["required"] == ["order_id", "amount"]
    assert entry.example == ~s({"order_id": "ord_123", "amount": 4200})

    assert {:ok, found} = AshHooks.Catalog.entry(Emitter, :order_paid)
    assert found.version == 2

    assert :error = AshHooks.Catalog.entry(Emitter, :never_declared)
  end

  test "an unpinned endpoint receives the CURRENT version's bytes" do
    endpoint = endpoint!()
    subscribe!(endpoint)

    {:ok, event} =
      AshHooks.Event.new(type: "order_paid", payload: Jason.encode!(%{"schema" => "v2"}))

    assert {:ok, [%{status: :deferred}]} = dispatch!(event)

    [row] = Ash.read!(Delivery, authorize?: false)
    assert row.payload == Jason.encode!(%{"schema" => "v2"})
  end

  test "an endpoint PINNED to a declared variant receives that version's bytes" do
    pinned = endpoint!(1)
    current = endpoint!()
    subscribe!(pinned)
    subscribe!(current)

    {:ok, event} =
      AshHooks.Event.new(type: "order_paid", payload: Jason.encode!(%{"schema" => "v2"}))

    assert {:ok, results} = dispatch!(event)
    assert Enum.all?(results, &(&1.status == :deferred))

    by_endpoint =
      Ash.read!(Delivery, authorize?: false) |> Map.new(&{&1.endpoint_id, &1.payload})

    assert by_endpoint[pinned.id] == Jason.encode!(%{"schema" => "v1"})
    assert by_endpoint[current.id] == Jason.encode!(%{"schema" => "v2"})
  end

  test "a pin to an undeclared version fails that endpoint closed" do
    pinned = endpoint!(9)
    subscribe!(pinned)

    {:ok, event} =
      AshHooks.Event.new(type: "order_paid", payload: Jason.encode!(%{"schema" => "v2"}))

    assert {:ok, [result]} = dispatch!(event)
    assert result.status == :endpoint_error
    assert result.error == :unknown_pinned_version

    # and nothing was written for it
    assert Ash.read!(Delivery, authorize?: false) == []
  end

  test "every contained variant failure collapses to variant_failed" do
    defmodule BadVariants do
      @moduledoc false
      def not_bytes(_event), do: {:ok, :not_binary}
      def erroring(_event), do: {:error, :nope}
      def crashing(_event), do: raise("variant crashed")
      def exiting(_event), do: exit(:variant_exit)
      def throwing(_event), do: throw(:variant_throw)
    end

    {:ok, event} = AshHooks.Event.new(type: "order_paid", payload: "{}")

    outbound = AshHooks.Info.outbound(Emitter, :order_paid)

    for fun <- [:not_bytes, :erroring, :crashing, :exiting, :throwing] do
      pinned = %{__struct__: Endpoint, pinned_payload_version: 1}

      versions = %{1 => {BadVariants, fun}}

      assert {:error, :variant_failed} =
               AshHooks.Catalog.payload(event, %{outbound | payload_versions: versions}, pinned)
    end
  end

  test "a failing variant builder fails that endpoint closed" do
    pinned = endpoint!(1)

    Ash.create!(
      Subscription,
      %{endpoint_id: pinned.id, event_types: ["order_canceled"]},
      authorize?: false
    )

    {:ok, event} =
      AshHooks.Event.new(type: "order_canceled", payload: Jason.encode!(%{"schema" => "v2"}))

    assert {:ok, [result]} = AshHooks.dispatch(Emitter, :order_canceled, event)
    assert result.status == :endpoint_error
    assert result.error == :variant_failed

    assert Ash.read!(Delivery, authorize?: false) == []
  end
end
