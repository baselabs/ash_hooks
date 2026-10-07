defmodule AshHooks.PayloadAttributeTest do
  @moduledoc """
  Consumer scenario (H1, the first-serious-consumer integration): a
  consumer's arch guard reserves `payload` as the name of the domain's
  SOLE payload store (sirtify's ADR-0003 sweep, evidence_arch_test.exs:
  230-251, non-vacuity probe at :251), so the package's injected
  `{:payload, :binary}` column collides with it — the guard goes RED on
  extension adoption. `payload_attribute` renames the injected column:
  the consumer's store keeps the name, and dispatch, signing, and the
  send path read the configured attribute end to end.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PayloadAttributeTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("payload_attribute_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PayloadAttributeTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("payload_attribute_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.PayloadAttributeTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PayloadAttributeTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("payload_attribute_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end

    # the consumer's sole store keeps `payload`; the ledger's exact-bytes
    # column is renamed (H1)
    outbound_delivery do
      payload_attribute(:event_bytes)
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PayloadAttributeTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("payload_attribute_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.PayloadAttributeTest.Subscription)
        deliveries(AshHooks.PayloadAttributeTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.PayloadAttributeTest.Endpoint)
      resource(AshHooks.PayloadAttributeTest.Subscription)
      resource(AshHooks.PayloadAttributeTest.Delivery)
      resource(AshHooks.PayloadAttributeTest.Emitter)
    end
  end

  # HTTP adapter test double: pops queued responses (last one repeats) and
  # records every call (the delivery suite's seam).
  defmodule HttpDouble do
    @moduledoc false
    @behaviour AshHooks.Http

    def start_link(responses) do
      Agent.start_link(fn -> {Enum.reverse(responses), []} end, name: __MODULE__)
    end

    def calls, do: Agent.get(__MODULE__, fn {_, c} -> Enum.reverse(c) end)

    @impl true
    def request(method, url, headers, body, opts) do
      Agent.update(__MODULE__, fn
        {[next | rest], calls} ->
          rest = if rest == [], do: [next], else: rest
          {rest, [%{method: method, url: url, headers: headers, body: body, opts: opts} | calls]}

        {[], calls} ->
          {[], [%{method: method, url: url, headers: headers, body: body, opts: opts} | calls]}
      end)

      {[next | _], _} = Agent.get(__MODULE__, fn state -> state end)
      next
    end
  end

  use ExUnit.Case, async: false

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.{Dispatcher, Event}
  alias AshHooks.Test.Repo

  @endpoints "payload_attribute_test_endpoints"
  @subscriptions "payload_attribute_test_subscriptions"
  @deliveries "payload_attribute_test_deliveries"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    create_tables!()

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    {:ok, _} = HttpDouble.start_link([{:ok, %{status: 200, headers: [], body: ~s({"ok": true})}}])
    :ok
  end

  defp create_tables! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL,
      previous_secret_ref TEXT,
      legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY,
      event_types TEXT NOT NULL,
      endpoint_id TEXT NOT NULL,
      signing_mode TEXT
    )
    """)

    # the renamed exact-bytes column: NO `payload` column exists on this
    # consumer's ledger (the sole-store reservation)
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY,
      event_uuid TEXT NOT NULL,
      event_type TEXT NOT NULL,
      event_bytes BLOB NOT NULL,
      endpoint_id TEXT NOT NULL,
      subscription_id TEXT,
      signing_mode TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0,
      response_status INTEGER,
      response_snippet TEXT,
      last_error TEXT,
      next_attempt_at TEXT,
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot JSONB
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )
  end

  defp endpoint!(url \\ "https://hooks.example.test/accept") do
    Ash.create!(Endpoint, %{url: url, secret_ref: "acme-main"}, authorize?: false)
  end

  defp subscription!(endpoint_id) do
    Ash.create!(Subscription, %{endpoint_id: endpoint_id, event_types: ["order_paid"]},
      authorize?: false
    )
  end

  defp event! do
    Event.new(type: :order_paid, payload: @payload) |> elem(1)
  end

  defp dispatch!(event \\ event!()) do
    {:ok, _} =
      Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: fn _delivery, _event -> :ok end)

    Ash.read!(Delivery, authorize?: false) |> hd()
  end

  defp config do
    [
      deliveries: Delivery,
      endpoints: Endpoint,
      secret_resolver: fn "acme-main" -> {:ok, @secret} end,
      http: HttpDouble,
      max_attempts: 3,
      base_backoff_seconds: 2,
      max_backoff_seconds: 3600,
      retry_after_cap_seconds: 86_400,
      ssrf_check: &AshHooks.Ssrf.registration_safe?/1,
      now: fn -> DateTime.utc_now() |> DateTime.truncate(:second) end
    ]
  end

  describe "the sole-store naming reservation (H1)" do
    test "no :payload attribute is injected — the arch-guard sweep stays green" do
      refute ResourceInfo.attribute(Delivery, :payload),
             "the injected payload column collides with the consumer's sole store (H1)"

      bytes = ResourceInfo.attribute(Delivery, :event_bytes)
      assert bytes.type == Ash.Type.Binary
      assert bytes.allow_nil? == false
    end

    test ":dispatch accepts the configured attribute, not :payload" do
      action = ResourceInfo.action(Delivery, :dispatch)
      assert :event_bytes in action.accept
      refute :payload in action.accept
    end

    test "dispatch persists the exact bytes under the configured attribute" do
      ep = endpoint!()
      subscription!(ep.id)

      row = dispatch!()

      assert row.event_bytes == @payload
      assert :payload not in Map.keys(row)
      assert row.endpoint_id == ep.id
      assert row.status == :pending
    end

    test "the send path posts and signs the configured attribute's bytes" do
      ep = endpoint!()
      subscription!(ep.id)
      row = dispatch!()

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config()
               )

      [call] = HttpDouble.calls()
      assert call.body == @payload
      assert %{"webhook-id" => id} = call.headers
      assert id == row.event_uuid

      assert {:ok, _} =
               AshHooks.Signing.verify(@payload, call.headers, @secret,
                 now: String.to_integer(call.headers["webhook-timestamp"])
               )

      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :succeeded
    end
  end

  describe "fail-closed reservation" do
    @renamed_resource """
    defmodule AshHooks.PayloadAttributeTest.Renamed do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.PayloadAttributeTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks.OutboundDelivery]

      actions do
        defaults([:read])
      end

      outbound_delivery do
        payload_attribute(:event_bytes)
      end
    end
    """

    @colliding_resource """
    defmodule AshHooks.PayloadAttributeTest.Colliding do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.PayloadAttributeTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks.OutboundDelivery]

      actions do
        defaults([:read])
      end

      outbound_delivery do
        payload_attribute(:status)
      end
    end
    """

    test "a configured name that collides with an injected field fails closed at compile" do
      assert_raise Spark.Error.DslError, ~r/collides/, fn ->
        Code.compile_string(@colliding_resource)
      end
    after
      :code.purge(AshHooks.PayloadAttributeTest.Colliding)
      :code.delete(AshHooks.PayloadAttributeTest.Colliding)
    end

    test "a non-colliding configured name compiles and injects under it" do
      assert Enum.any?(Code.compile_string(@renamed_resource), fn {m, _} ->
               m == AshHooks.PayloadAttributeTest.Renamed
             end)

      assert ResourceInfo.attribute(AshHooks.PayloadAttributeTest.Renamed, :event_bytes)
      refute ResourceInfo.attribute(AshHooks.PayloadAttributeTest.Renamed, :payload)
    after
      :code.purge(AshHooks.PayloadAttributeTest.Renamed)
      :code.delete(AshHooks.PayloadAttributeTest.Renamed)
    end
  end
end
