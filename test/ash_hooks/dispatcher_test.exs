defmodule AshHooks.DispatcherTest do
  @moduledoc """
  The outbound fanout dispatcher over REAL sqlite tables: the durable
  per-endpoint delivery rows (unique on endpoint+event — the SAME pair as
  the Oban job uniqueness keys), per-endpoint enqueue isolation (the
  ACCEPT), the claim-then-enqueue repair CAS, conflict validation before
  any write, and the deferred default.

  The enqueue seam is an injected test double throughout — this suite is
  Oban-free by construction and runs identically on the NO_OPTIONAL leg.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DispatcherTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("dispatcher_test_endpoints")
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
      domain: AshHooks.DispatcherTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("dispatcher_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.DispatcherTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DispatcherTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("dispatcher_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.DispatcherTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("dispatcher_test_emitters")
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
        subscriptions(AshHooks.DispatcherTest.Subscription)
        deliveries(AshHooks.DispatcherTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.DispatcherTest.Endpoint)
      resource(AshHooks.DispatcherTest.Subscription)
      resource(AshHooks.DispatcherTest.Delivery)
      resource(AshHooks.DispatcherTest.Emitter)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Dispatcher
  alias AshHooks.Event
  alias AshHooks.Test.Repo

  require Ash.Query

  @endpoints "dispatcher_test_endpoints"
  @subscriptions "dispatcher_test_subscriptions"
  @deliveries "dispatcher_test_deliveries"
  @payload Jason.encode!(%{"order" => 1, "total" => 42})

  setup_all do
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

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY,
      event_uuid TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload BLOB NOT NULL,
      endpoint_id TEXT NOT NULL,
      subscription_id TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0,
      response_status INTEGER,
      response_snippet TEXT,
      last_error TEXT,
      next_attempt_at TEXT
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
    :ok
  end

  defp endpoint!(url \\ "https://example.test/hook") do
    Ash.create!(Endpoint, %{url: url, secret_ref: "ref-1"}, authorize?: false)
  end

  defp subscription!(endpoint_id, opts \\ []) do
    Ash.create!(Subscription, Keyword.put(opts, :endpoint_id, endpoint_id), authorize?: false)
  end

  defp event!(id \\ nil) do
    attrs = [type: :order_paid, payload: @payload]
    attrs = if id, do: Keyword.put(attrs, :id, id), else: attrs
    Event.new(attrs) |> elem(1)
  end

  defp delivery_rows do
    Ash.read!(Delivery, authorize?: false)
  end

  defp enqueue_ok(_delivery, _event), do: :ok

  defp enqueue_error(_delivery, _event), do: {:error, :queue_down}

  defp enqueue_raises(_delivery, _event), do: raise("boom")

  describe "fanout (the ACCEPT): per-endpoint enqueue isolation" do
    test "one endpoint's enqueue FAILURE does not stop the others" do
      good = endpoint!("https://good.test/hook")
      bad = endpoint!("https://bad.test/hook")
      subscription!(good.id, event_types: ["order_paid"])
      subscription!(bad.id, event_types: ["order_paid"])

      {:ok, results} =
        Dispatcher.dispatch(
          Emitter,
          :order_paid,
          event!(),
          enqueue: fn delivery, event ->
            if delivery.endpoint_id == bad.id, do: enqueue_error(delivery, event), else: :ok
          end
        )

      by_endpoint = Map.new(results, &{&1.endpoint_id, &1})

      assert by_endpoint[good.id].status == :created
      assert by_endpoint[bad.id].status == :enqueue_failed

      rows = delivery_rows()
      assert length(rows) == 2

      good_row = Enum.find(rows, &(&1.endpoint_id == good.id))
      bad_row = Enum.find(rows, &(&1.endpoint_id == bad.id))

      assert good_row.status == :pending
      assert bad_row.status == :enqueue_failed
      assert bad_row.last_error =~ "queue_down"
    end

    test "one endpoint's enqueue RAISE does not stop the others" do
      good = endpoint!("https://good.test/hook")
      bad = endpoint!("https://bad.test/hook")
      subscription!(good.id)
      subscription!(bad.id)

      assert {:ok, results} =
               Dispatcher.dispatch(
                 Emitter,
                 :order_paid,
                 event!(),
                 enqueue: fn delivery, event ->
                   if delivery.endpoint_id == bad.id,
                     do: enqueue_raises(delivery, event),
                     else: :ok
                 end
               )

      by_endpoint = Map.new(results, &{&1.endpoint_id, &1})
      assert by_endpoint[good.id].status == :created
      assert by_endpoint[bad.id].status == :enqueue_failed
      assert Enum.find(delivery_rows(), &(&1.endpoint_id == bad.id)).last_error =~ "boom"
    end
  end

  describe "durable rows" do
    test "persists the exact payload bytes, type, and both identity keys" do
      ep = endpoint!()
      subscription!(ep.id)

      {:ok, _} = Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      [row] = delivery_rows()
      assert row.payload == @payload
      assert row.event_type == "order_paid"
      assert row.endpoint_id == ep.id
      assert String.starts_with?(row.event_uuid, "msg_")
      assert row.status == :pending
      assert row.attempts == 0
    end

    test "double-dispatch of one event → ONE row, :duplicate (append-only count)" do
      ep = endpoint!()
      subscription!(ep.id)
      event = event!()

      {:ok, first} = Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: &enqueue_ok/2)
      {:ok, second} = Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: &enqueue_ok/2)

      assert hd(first).status == :created
      assert hd(second).status == :duplicate
      assert length(delivery_rows()) == 1
    end

    test "distinct events to one endpoint → distinct rows" do
      ep = endpoint!()
      subscription!(ep.id)

      {:ok, _} = Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)
      {:ok, _} = Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      assert length(delivery_rows()) == 2
    end
  end

  describe "subscription matching" do
    test "\"*\" default receives every event type" do
      ep = endpoint!()
      subscription!(ep.id)
      ep_id = ep.id

      assert {:ok, [%{status: :created, endpoint_id: ^ep_id}]} =
               Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)
    end

    test "a non-matching filter receives nothing (no row, no enqueue)" do
      ep = endpoint!()
      subscription!(ep.id, event_types: ["other_type"])

      assert {:ok, []} =
               Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      assert delivery_rows() == []
    end

    test "a DISABLED endpoint is skipped entirely — no row, siblings proceed" do
      off = endpoint!()
      on = endpoint!()
      Ash.update!(off, %{status: :disabled}, authorize?: false)
      subscription!(off.id)
      subscription!(on.id)

      assert {:ok, results} =
               Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      assert length(results) == 1
      assert delivery_rows() |> length() == 1
      assert hd(delivery_rows()).endpoint_id == on.id
    end

    test "a subscription whose endpoint row is GONE is isolated, not fatal" do
      ghost = endpoint!()
      live = endpoint!()
      subscription!(ghost.id)
      subscription!(live.id)
      Repo.query!("DELETE FROM #{@endpoints} WHERE id = ?", [ghost.id])

      assert {:ok, results} =
               Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      assert length(results) == 1
      assert hd(results).endpoint_id == live.id
      assert length(delivery_rows()) == 1
    end
  end

  describe "deferred default (no enqueuer configured)" do
    test "rows persist :pending with :deferred results" do
      ep = endpoint!()
      subscription!(ep.id)
      ep_id = ep.id

      assert {:ok, [%{status: :deferred, endpoint_id: ^ep_id}]} =
               Dispatcher.dispatch(Emitter, :order_paid, event!())

      [row] = delivery_rows()
      assert row.status == :pending
    end
  end

  describe "enqueue-failed repair (claim-then-enqueue CAS)" do
    test "re-dispatch after :enqueue_failed retries the enqueue" do
      ep = endpoint!()
      subscription!(ep.id)
      event = event!()

      {:ok, _} =
        Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: &enqueue_error/2)

      assert hd(delivery_rows()).status == :enqueue_failed

      {:ok, [result]} =
        Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: &enqueue_ok/2)

      assert result.status == :created
      row = hd(delivery_rows())
      assert row.status == :pending
      assert row.last_error == nil
    end

    @tag :concurrent_repair
    test "a true process race on the repair enqueues EXACTLY once (the CAS)" do
      ep = endpoint!()
      subscription!(ep.id)
      event = event!()

      {:ok, _} =
        Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: &enqueue_error/2)

      assert hd(delivery_rows()).status == :enqueue_failed

      parent = self()
      n = 4
      counter = :counters.new(1, [:write_concurrency])

      pids =
        for i <- 1..n do
          spawn(fn ->
            send(parent, {:ready, i})

            receive do
              :go -> :ok
            after
              10_000 -> exit(:no_go)
            end

            result =
              try do
                Dispatcher.dispatch(Emitter, :order_paid, event,
                  enqueue: fn _delivery, _event ->
                    :counters.add(counter, 1, 1)
                    :ok
                  end
                )
              rescue
                e -> {:crashed, Exception.format(:error, e)}
              end

            send(parent, {:result, result})
          end)
        end

      Enum.each(1..n, fn _ -> receive(do: ({:ready, _} -> :ok)) end)
      Enum.each(pids, &send(&1, :go))

      results =
        Enum.map(1..n, fn _ ->
          receive do
            {:result, result} -> result
          after
            15_000 -> {:timeout, :no_result}
          end
        end)

      # The effect-once invariant: the enqueuer ran exactly once regardless
      # of how many dispatchers raced the repair. (CAS losers — and any
      # transient sqlite busy-lock errors under write contention — surface
      # as :duplicate/:endpoint_error; the enqueue count is what must hold.)
      assert :counters.get(counter, 1) == 1

      assert Enum.all?(results, &match?({:ok, _}, &1))

      assert hd(delivery_rows()).status == :pending
    end

    test "a :pending row is NOT re-enqueued by re-dispatch (:duplicate)" do
      ep = endpoint!()
      subscription!(ep.id)
      event = event!()

      Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: &enqueue_ok/2)

      {:ok, [result]} =
        Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: &enqueue_raises/2)

      assert result.status == :duplicate
      assert hd(delivery_rows()).status == :pending
    end
  end

  describe "conflict validation (before any row write)" do
    test "divergent effective signing modes for one endpoint → global error, ZERO rows" do
      ep = endpoint!()
      subscription!(ep.id, event_types: ["order_paid"], signing_mode: :standard)
      subscription!(ep.id, event_types: ["*"], signing_mode: :dual)

      assert {:error, :conflicting_subscriptions} =
               Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      assert delivery_rows() == []
    end

    test "two subscriptions agreeing on the mode are fine" do
      ep = endpoint!()
      subscription!(ep.id, event_types: ["order_paid"], signing_mode: :dual)
      subscription!(ep.id, event_types: ["*"], signing_mode: :dual)

      assert {:ok, [_one]} =
               Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      assert length(delivery_rows()) == 1
    end
  end

  describe "cross-vendor review regressions" do
    test "an enqueuer EXIT is an enqueue failure, isolated (siblings proceed)" do
      good = endpoint!("https://good.test/hook")
      bad = endpoint!("https://bad.test/hook")
      subscription!(good.id)
      subscription!(bad.id)

      {:ok, results} =
        Dispatcher.dispatch(
          Emitter,
          :order_paid,
          event!(),
          enqueue: fn delivery, _event ->
            if delivery.endpoint_id == bad.id, do: exit(:queue_timeout), else: :ok
          end
        )

      by_endpoint = Map.new(results, &{&1.endpoint_id, &1.status})
      assert by_endpoint[good.id] == :created
      assert by_endpoint[bad.id] == :enqueue_failed

      bad_row = Enum.find(delivery_rows(), &(&1.endpoint_id == bad.id))
      assert bad_row.status == :enqueue_failed
      assert bad_row.last_error =~ "exit"
    end

    test "an enqueuer THROW is an enqueue failure, isolated" do
      good = endpoint!("https://good.test/hook")
      bad = endpoint!("https://bad.test/hook")
      subscription!(good.id)
      subscription!(bad.id)

      {:ok, results} =
        Dispatcher.dispatch(
          Emitter,
          :order_paid,
          event!(),
          enqueue: fn delivery, _event ->
            if delivery.endpoint_id == bad.id, do: throw(:oops), else: :ok
          end
        )

      by_endpoint = Map.new(results, &{&1.endpoint_id, &1.status})
      assert by_endpoint[good.id] == :created
      assert by_endpoint[bad.id] == :enqueue_failed
    end

    test "a forged %Event{} struct fails validation before any row" do
      ep = endpoint!()
      subscription!(ep.id)

      forged = %AshHooks.Event{id: "evil.id", type: "order_paid", payload: "{}", metadata: %{}}

      assert {:error, _} =
               Dispatcher.dispatch(Emitter, :order_paid, forged, enqueue: &enqueue_ok/2)

      assert delivery_rows() == []
    end

    test "an event whose type diverges from the declaration errors before any row" do
      ep = endpoint!()
      subscription!(ep.id, event_types: ["*"])

      {:ok, other_event} = AshHooks.Event.new(type: :something_else, payload: "{}")

      assert {:error, _} =
               Dispatcher.dispatch(Emitter, :order_paid, other_event, enqueue: &enqueue_ok/2)

      assert delivery_rows() == []
    end

    test "an endpoint READ ERROR surfaces as :endpoint_error, not a silent skip" do
      live = endpoint!()
      subscription!(live.id)
      subscription!(endpoint!().id)

      # stage a non-NotFound read error: the endpoint table itself vanishes
      # (analogous to a pool timeout / transient storage error on any layer)
      Repo.query!("DROP TABLE #{@endpoints}")

      assert {:ok, results} =
               Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: &enqueue_ok/2)

      assert length(results) == 2
      assert Enum.all?(results, &(&1.status == :endpoint_error))
      assert delivery_rows() == []

      Repo.query!("""
      CREATE TABLE #{@endpoints} (
        id TEXT PRIMARY KEY,
        url TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'enabled',
        secret_ref TEXT NOT NULL,
        previous_secret_ref TEXT,
        legacy_secret_ref TEXT,
        legacy_previous_secret_ref TEXT
      )
      """)
    end
  end

  describe "global fail-fast" do
    test "an unknown outbound name errors before anything runs" do
      ep = endpoint!()
      subscription!(ep.id)

      assert {:error, _reason} =
               Dispatcher.dispatch(Emitter, :nope, event!(), enqueue: &enqueue_ok/2)

      assert delivery_rows() == []
    end

    test "an invalid event errors before anything runs" do
      ep = endpoint!()
      subscription!(ep.id)

      assert {:error, _reason} =
               Dispatcher.dispatch(Emitter, :order_paid, :not_an_event, enqueue: &enqueue_ok/2)

      assert delivery_rows() == []
    end
  end
end
