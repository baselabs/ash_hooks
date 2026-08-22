if Code.ensure_loaded?(AshSqlite) do
  defmodule AshHooks.DispatcherBusyRetryTest do
    @moduledoc """
    Bounded transient-busy retry for the dispatcher's storage ops — the
    outbound twin of the ingress busy-retry fixture. Same substrate: a
    throwaway repo with a small pool and a tiny busy_timeout, schema
    settled under a single connection before the pool opens.
    """

    defmodule Endpoint do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.DispatcherBusyRetryTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.Endpoint]

      sqlite do
        table("dispatch_busy_endpoints")
        repo(AshHooks.Test.BusyRepo)
      end

      actions do
        defaults([:read, :create, :update])
        default_accept(:*)
      end
    end

    defmodule Subscription do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.DispatcherBusyRetryTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.Subscription]

      sqlite do
        table("dispatch_busy_subscriptions")
        repo(AshHooks.Test.BusyRepo)
      end

      actions do
        defaults([:read, :create])
        default_accept(:*)
      end

      subscription do
        endpoint_resource(AshHooks.DispatcherBusyRetryTest.Endpoint)
      end
    end

    defmodule Delivery do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.DispatcherBusyRetryTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      sqlite do
        table("dispatch_busy_deliveries")
        repo(AshHooks.Test.BusyRepo)
      end

      actions do
        defaults([:read])
      end
    end

    defmodule Emitter do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.DispatcherBusyRetryTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks]

      sqlite do
        table("dispatch_busy_emitters")
        repo(AshHooks.Test.BusyRepo)
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
          subscriptions(AshHooks.DispatcherBusyRetryTest.Subscription)
          deliveries(AshHooks.DispatcherBusyRetryTest.Delivery)
        end
      end
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.DispatcherBusyRetryTest.Endpoint)
        resource(AshHooks.DispatcherBusyRetryTest.Subscription)
        resource(AshHooks.DispatcherBusyRetryTest.Delivery)
        resource(AshHooks.DispatcherBusyRetryTest.Emitter)
      end
    end

    use ExUnit.Case, async: false

    alias AshHooks.Dispatcher
    alias AshHooks.Event
    alias AshHooks.Test.BusyRepo

    @endpoints "dispatch_busy_endpoints"
    @subscriptions "dispatch_busy_subscriptions"
    @deliveries "dispatch_busy_deliveries"
    @emitters "dispatch_busy_emitters"
    @payload Jason.encode!(%{"order" => 1})

    setup_all do
      db_path =
        Path.join(System.tmp_dir!(), "ash_hooks_dispatch_busy_#{System.unique_integer()}.sqlite3")

      Application.put_env(:ash_hooks, BusyRepo,
        database: db_path,
        pool_size: 1,
        journal_mode: :wal,
        busy_timeout: 5_000
      )

      {:ok, _boot} = BusyRepo.start_link()

      BusyRepo.query!("""
      CREATE TABLE #{@endpoints} (
        id TEXT PRIMARY KEY, url TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'enabled', secret_ref TEXT NOT NULL,
        previous_secret_ref TEXT, legacy_secret_ref TEXT,
        legacy_previous_secret_ref TEXT
      )
      """)

      BusyRepo.query!("""
      CREATE TABLE #{@subscriptions} (
        id TEXT PRIMARY KEY, event_types TEXT NOT NULL,
        endpoint_id TEXT NOT NULL, signing_mode TEXT
      )
      """)

      BusyRepo.query!("""
      CREATE TABLE #{@deliveries} (
        id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
        payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
        signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
        attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
        response_snippet TEXT, last_error TEXT, next_attempt_at TEXT
      )
      """)

      BusyRepo.query!("CREATE TABLE #{@emitters} (id TEXT PRIMARY KEY)")

      BusyRepo.query!(
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
      )

      :ok = BusyRepo.stop(30_000)
      Process.sleep(200)

      Application.put_env(:ash_hooks, BusyRepo,
        database: db_path,
        pool_size: 3,
        journal_mode: :wal,
        busy_timeout: 50
      )

      {:ok, _boot} = BusyRepo.start_link()

      on_exit(fn -> File.rm(db_path) end)

      :ok
    end

    setup do
      BusyRepo.query!("DELETE FROM #{@deliveries}")
      BusyRepo.query!("DELETE FROM #{@subscriptions}")
      BusyRepo.query!("DELETE FROM #{@endpoints}")
      :ok
    end

    defp fixture! do
      ep =
        Ash.create!(Endpoint, %{url: "https://busy.test/hook", secret_ref: "ref-1"},
          authorize?: false
        )

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      ep
    end

    test "an upsert that hits write contention retries and converges" do
      ep = fixture!()

      parent = self()

      holder =
        spawn(fn ->
          try do
            BusyRepo.transaction(fn ->
              BusyRepo.query!("UPDATE #{@deliveries} SET attempts = attempts")
              send(parent, :locked)

              receive do
                :release -> :ok
              after
                900 -> :ok
              end
            end)
          after
            send(parent, :released)
          end
        end)

      receive do
        :locked -> :ok
      after
        5_000 -> flunk("lock holder never acquired the write lock")
      end

      {:ok, event} = Event.new(type: :order_paid, payload: @payload)

      assert {:ok, [%{status: :deferred, endpoint_id: ep_id}]} =
               Dispatcher.dispatch(Emitter, :order_paid, event)

      assert ep_id == ep.id

      rows = Ash.read!(Delivery, authorize?: false)
      uuid = event.id
      assert [%{status: :pending, event_uuid: ^uuid}] = rows

      send(holder, :release)
      assert_receive :released, 5_000
    end
  end
end
