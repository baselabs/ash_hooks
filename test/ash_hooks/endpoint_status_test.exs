defmodule AshHooks.EndpointStatusTest do
  @moduledoc """
  Consumer scenario (H4, the first-serious-consumer integration): the
  consumer's endpoint register carries its OWN enable switch (sirtify's
  `active` boolean + `:deactivate`) beside the package's injected
  `status :enabled | :disabled` — and the dispatcher matched ONLY
  `%{status: :enabled}` while the send path dead-lettered only on
  `%{status: :disabled}`, so the consumer's own off switch was silently
  bypassed: delivery kept flowing while the consumer's gate reported
  disabled. `status_attribute` maps the package onto the consumer's
  switch — ONE attribute, so two switches cannot disagree.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EndpointStatusTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("endpoint_status_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      # the consumer's own switch (sirtify's `active`)
      attribute(:active, :boolean, allow_nil?: false, default: true, public?: true)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end

    endpoint do
      status_attribute(:active)
      enabled_values([true])
      disabled_value(false)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EndpointStatusTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("endpoint_status_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.EndpointStatusTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EndpointStatusTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("endpoint_status_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EndpointStatusTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("endpoint_status_test_emitters")
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
        subscriptions(AshHooks.EndpointStatusTest.Subscription)
        deliveries(AshHooks.EndpointStatusTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.EndpointStatusTest.Endpoint)
      resource(AshHooks.EndpointStatusTest.Subscription)
      resource(AshHooks.EndpointStatusTest.Delivery)
      resource(AshHooks.EndpointStatusTest.Emitter)
    end
  end

  # HTTP adapter test double (the delivery suite's seam): pops queued
  # responses (last one repeats), records every call.
  defmodule HttpDouble do
    @moduledoc false
    @behaviour AshHooks.Http

    def start_link(responses) do
      Agent.start_link(fn -> {Enum.reverse(responses), []} end, name: __MODULE__)
    end

    def set_responses(responses) do
      Agent.update(__MODULE__, fn {_, calls} -> {Enum.reverse(responses), calls} end)
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

  @endpoints "endpoint_status_test_endpoints"
  @subscriptions "endpoint_status_test_subscriptions"
  @deliveries "endpoint_status_test_deliveries"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      active BOOLEAN NOT NULL DEFAULT 1,
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

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY,
      event_uuid TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload BLOB NOT NULL,
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

  defp endpoint!(active \\ true) do
    Ash.create!(
      Endpoint,
      %{url: "https://hooks.example.test/accept", secret_ref: "acme-main", active: active},
      authorize?: false
    )
  end

  defp event! do
    Event.new(type: :order_paid, payload: @payload) |> elem(1)
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

  describe "the consumer-owned switch (H4)" do
    test "the package injects NO status attribute — one switch, no disagreement" do
      refute ResourceInfo.attribute(Endpoint, :status),
             "two switches can silently disagree (H4) — the mapping owns the attribute"

      assert ResourceInfo.attribute(Endpoint, :active)
    end

    # ── fail-closed arms: the H8 silent-zero-delivery failure class must
    # be a COMPILE error here, never a runtime posture ──

    @mapped_base """
    defmodule AshHooks.EndpointStatusTest.Mapped do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.EndpointStatusTest.Domain,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks.Endpoint]

      attributes do
        uuid_primary_key(:id)
        attribute(:active, :boolean, allow_nil?: false, default: true)
      end

      actions do
        defaults([:read])
      end

      endpoint do
        status_attribute(:active)
        enabled_values([true])
        disabled_value(false)
      end
    end
    """

    test "mapping onto the primary key fails closed (the 410 breaker could never write it)" do
      source = String.replace(@mapped_base, "status_attribute(:active)", "status_attribute(:id)")

      assert_raise Spark.Error.DslError, ~r/primary key/, fn ->
        Code.compile_string(source)
      end
    after
      :code.purge(AshHooks.EndpointStatusTest.Mapped)
      :code.delete(AshHooks.EndpointStatusTest.Mapped)
    end

    test "mapping onto an injected field fails closed" do
      source = String.replace(@mapped_base, "status_attribute(:active)", "status_attribute(:url)")

      assert_raise Spark.Error.DslError, ~r/collides/, fn ->
        Code.compile_string(source)
      end
    after
      :code.purge(AshHooks.EndpointStatusTest.Mapped)
      :code.delete(AshHooks.EndpointStatusTest.Mapped)
    end

    test "mapping onto an undeclared attribute fails closed" do
      source =
        String.replace(@mapped_base, "status_attribute(:active)", "status_attribute(:nowhere)")

      assert_raise Spark.Error.DslError, ~r/not an attribute declared/, fn ->
        Code.compile_string(source)
      end
    after
      :code.purge(AshHooks.EndpointStatusTest.Mapped)
      :code.delete(AshHooks.EndpointStatusTest.Mapped)
    end

    test "a disabled_value inside enabled_values fails closed (the breaker would write a no-op)" do
      source =
        @mapped_base
        |> String.replace("enabled_values([true])", "enabled_values([true, false])")

      assert_raise Spark.Error.DslError, ~r/inside enabled_values/, fn ->
        Code.compile_string(source)
      end
    after
      :code.purge(AshHooks.EndpointStatusTest.Mapped)
      :code.delete(AshHooks.EndpointStatusTest.Mapped)
    end

    test "omitting enabled_values/disabled_value fails closed (a defaulted mapping delivers NOTHING)" do
      source =
        @mapped_base
        |> String.replace("enabled_values([true])", "")
        |> String.replace("disabled_value(false)", "")

      assert_raise Spark.Error.DslError,
                   ~r/requires explicit enabled_values and disabled_value/,
                   fn ->
                     Code.compile_string(source)
                   end
    after
      :code.purge(AshHooks.EndpointStatusTest.Mapped)
      :code.delete(AshHooks.EndpointStatusTest.Mapped)
    end

    test "the consumer's off switch suppresses dispatch (no delivery row)" do
      ep = endpoint!(false)

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      {:ok, results} =
        Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: fn _d, _e -> :ok end)

      assert results == []
      assert [] = Ash.read!(Delivery, authorize?: false)
    end

    test "the send path dead-letters against the consumer's switch" do
      ep = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      {:ok, _} =
        Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: fn _d, _e -> :ok end)

      row = Ash.read!(Delivery, authorize?: false) |> hd()

      # the consumer deactivates between dispatch and the send attempt
      Ash.update!(ep, %{active: false}, authorize?: false)

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config()
               )

      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :dead_letter
      assert final.last_error == "endpoint_disabled"
    end

    test "a 410 disables through the consumer's switch (the durable circuit breaker)" do
      ep = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      {:ok, _} =
        Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: fn _d, _e -> :ok end)

      row = Ash.read!(Delivery, authorize?: false) |> hd()

      HttpDouble.set_responses([{:ok, %{status: 410, headers: [], body: ""}}])

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config()
               )

      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :dead_letter

      # the durable disable landed on the CONSUMER's attribute
      assert Ash.get!(Endpoint, ep.id, authorize?: false).active == false
    end
  end
end
