defmodule AshHooks.PostgresConsumerTest do
  @moduledoc """
  The AshPostgres consumer leg (CI's postgres job): the
  first-serious-consumer integration's FULL shape on real Postgres —
  uuid_v7 primary keys on every resource (non-writable: H2), a renamed
  exact-bytes column under a sole-store `payload` reservation (H1), an
  atom-typed closed-enum subscription register (H8), a consumer-owned
  `active` enable switch (H4), and an append-only ledger with NO destroy
  action (H6). The suite's own sqlite substrate could not surface H1/H2
  upstream — this leg is the mechanical guarantee they stay fixed on the
  data layer real consumers run.

  Connection config: ASH_HOOKS_TEST_PG_* (test_helper); the suite is
  excluded entirely unless ASH_HOOKS_POSTGRES=1.
  """

  # credo:disable-for-this-file Credo.Check.Readability.MaxLineLength

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PostgresConsumerTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks.Endpoint]

    postgres do
      table("pg_consumer_endpoints")
      repo(AshHooks.TestPostgres.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
      # the consumer's own switch (H4)
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
      domain: AshHooks.PostgresConsumerTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks.Subscription]

    postgres do
      table("pg_consumer_subscriptions")
      repo(AshHooks.TestPostgres.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)

      # the consumer's closed atom register (H8) — replaces the injected
      # {:array, :string} default ["*"]
      attribute(:event_types, {:array, :atom},
        allow_nil?: false,
        public?: true,
        constraints: [min_length: 1, items: [one_of: [:order_paid, :order_shipped]]]
      )
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.PostgresConsumerTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PostgresConsumerTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    postgres do
      table("pg_consumer_deliveries")
      repo(AshHooks.TestPostgres.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
      timestamps()
    end

    actions do
      defaults([:read])
    end

    outbound_delivery do
      # the sole-store reservation (H1) + the append-only ledger (H6)
      payload_attribute(:event_bytes)
      prune_action(:none)
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PostgresConsumerTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks]

    postgres do
      table("pg_consumer_emitters")
      repo(AshHooks.TestPostgres.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.PostgresConsumerTest.Subscription)
        deliveries(AshHooks.PostgresConsumerTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.PostgresConsumerTest.Endpoint)
      resource(AshHooks.PostgresConsumerTest.Subscription)
      resource(AshHooks.PostgresConsumerTest.Delivery)
      resource(AshHooks.PostgresConsumerTest.Emitter)
    end
  end

  # HTTP adapter test double (the delivery suite's seam)
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
  alias AshHooks.TestPostgres.Repo

  @endpoints "pg_consumer_endpoints"
  @subscriptions "pg_consumer_subscriptions"
  @deliveries "pg_consumer_deliveries"
  @emitters "pg_consumer_emitters"
  @payload Jason.encode!(%{"order" => 1, "pg" => true})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    Repo.query!("CREATE TABLE IF NOT EXISTS #{@emitters} (id UUID PRIMARY KEY)")

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id UUID PRIMARY KEY,
      url TEXT NOT NULL,
      active BOOLEAN NOT NULL DEFAULT TRUE,
      secret_ref TEXT NOT NULL,
      previous_secret_ref TEXT,
      legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id UUID PRIMARY KEY,
      event_types TEXT[] NOT NULL,
      endpoint_id UUID NOT NULL,
      signing_mode TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id UUID PRIMARY KEY,
      event_uuid TEXT NOT NULL,
      event_type TEXT NOT NULL,
      event_bytes BYTEA NOT NULL,
      endpoint_id UUID NOT NULL,
      subscription_id UUID,
      signing_mode TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0,
      response_status INTEGER,
      response_snippet TEXT,
      last_error TEXT,
      next_attempt_at TIMESTAMP,
      inserted_at TIMESTAMP NOT NULL,
      updated_at TIMESTAMP NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

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

  defp event!(id \\ nil) do
    attrs = [type: :order_paid, payload: @payload]
    attrs = if id, do: Keyword.put(attrs, :id, id), else: attrs
    Event.new(attrs) |> elem(1)
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

  @moduletag :postgres

  describe "the consumer shape compiles and holds its arch pins (H1/H2/H6)" do
    test "no injected :payload column, no destroy action, no accepted PK" do
      refute ResourceInfo.attribute(Delivery, :payload)
      assert ResourceInfo.attribute(Delivery, :event_bytes)
      assert :destroy not in Enum.map(ResourceInfo.actions(Delivery), & &1.type)
      refute :id in ResourceInfo.action(Delivery, :dispatch).accept
    end
  end

  describe "the full dispatch → send round trip on Postgres" do
    test "dispatch dedups and sends the exact bytes, uuid_v7 ids intact" do
      ep = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: [:order_paid]},
        authorize?: false
      )

      # a DETERMINISTIC id (H7): a producer re-fire matches the same row
      event = event!("msg_order-1")

      {:ok, first} =
        Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: fn _d, _e -> :ok end)

      {:ok, second} =
        Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: fn _d, _e -> :ok end)

      assert [%{status: :created}] = first
      assert [%{status: :duplicate}] = second

      rows = Ash.read!(Delivery, authorize?: false)
      assert length(rows) == 1
      row = hd(rows)
      assert row.event_bytes == @payload
      assert binary_part(row.id, 14, 1) == "7"

      assert :ok =
               DeliveryRuntime.run(
                 %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
                 config()
               )

      [call] = HttpDouble.calls()
      assert call.body == @payload

      assert {:ok, _} =
               AshHooks.Signing.verify(@payload, call.headers, @secret,
                 now: String.to_integer(call.headers["webhook-timestamp"])
               )

      assert Ash.get!(Delivery, row.id, authorize?: false).status == :succeeded
    end

    test "the consumer's off switch suppresses dispatch (H4 on Postgres)" do
      ep = endpoint!(false)

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: [:order_paid]},
        authorize?: false
      )

      {:ok, results} =
        Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: fn _d, _e -> :ok end)

      assert results == []
      assert [] = Ash.read!(Delivery, authorize?: false)
    end

    test "a 410 disables through the consumer's switch (H4 durable breaker on Postgres)" do
      ep = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: [:order_paid]},
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

      assert Ash.get!(Delivery, row.id, authorize?: false).status == :dead_letter
      assert Ash.get!(Endpoint, ep.id, authorize?: false).active == false
    end
  end
end
