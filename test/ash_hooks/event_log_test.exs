defmodule AshHooks.EventLogTest do
  @moduledoc """
  The event log: one row per DISPATCHED event — id, type, version, time,
  exact payload bytes — recorded whether or not any endpoint was enabled,
  with its own retention. Queried by type and time range with keyset
  pagination. Replayed — one event or a filtered set — to a CHOSEN
  endpoint (including one that was off when the event happened or was
  added later), keeping the event id and recording who asked.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventLogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("event_log_endpoints")
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
      domain: AshHooks.EventLogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("event_log_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.EventLogTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventLogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("event_log_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end

    outbound_delivery do
      resend_tracking(:on)
    end
  end

  defmodule EventLog do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventLogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundEvent]

    sqlite do
      table("event_log_events")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.EventLogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("event_log_emitters")
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
        subscriptions(AshHooks.EventLogTest.Subscription)
        deliveries(AshHooks.EventLogTest.Delivery)
        events(AshHooks.EventLogTest.EventLog)
        version(3)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.EventLogTest.Endpoint)
      resource(AshHooks.EventLogTest.Subscription)
      resource(AshHooks.EventLogTest.Delivery)
      resource(AshHooks.EventLogTest.EventLog)
      resource(AshHooks.EventLogTest.Emitter)
      resource(AshHooks.EventLogTest.TenantLog)
      resource(AshHooks.EventLogTest.MismatchedEmitter)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo

  @endpoints "event_log_endpoints"
  @subscriptions "event_log_subscriptions"
  @deliveries "event_log_deliveries"
  @events "event_log_events"
  @emitters "event_log_emitters"
  @payload Jason.encode!(%{"order" => 1})

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
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
      endpoint_snapshot TEXT,
      resend_baseline INTEGER NOT NULL DEFAULT 0,
      resend_count INTEGER NOT NULL DEFAULT 0,
      last_resend_by TEXT, last_resend_at TEXT,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@events} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      version INTEGER, payload BLOB NOT NULL,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@events}_unique_event_index ON #{@events} (event_uuid)"
    )

    Repo.query!("CREATE TABLE IF NOT EXISTS #{@emitters} (id TEXT PRIMARY KEY)")

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@events}")
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@emitters}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@events}")
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@emitters}")
    :ok
  end

  defp endpoint!(status \\ :enabled) do
    Ash.create!(
      Endpoint,
      %{url: "https://hooks.example.test/hook", secret_ref: "el-main", status: status},
      authorize?: false
    )
  end

  defp dispatch!(id) do
    {:ok, event} = AshHooks.Event.new(type: "order_paid", payload: @payload, id: id)
    AshHooks.dispatch(Emitter, :order_paid, event)
  end

  test "each dispatched event records ONCE, whatever the fanout" do
    a = endpoint!()
    b = endpoint!()

    for ep <- [a, b],
        do:
          Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
            authorize?: false
          )

    assert {:ok, results} = dispatch!("msg_el_multi")
    assert length(results) == 2

    [logged] = Ash.read!(EventLog, authorize?: false)
    assert logged.event_uuid == "msg_el_multi"
    assert logged.event_type == "order_paid"
    assert logged.version == 3
    assert logged.payload == @payload
    assert logged.inserted_at != nil
  end

  test "an event with NO matching endpoint still records" do
    endpoint!(:disabled)

    assert {:ok, []} = dispatch!("msg_el_none")

    [logged] = Ash.read!(EventLog, authorize?: false)
    assert logged.event_uuid == "msg_el_none"
  end

  test "a re-dispatch of the same event id records once (idempotent)" do
    endpoint!()
    dispatch!("msg_el_twice")
    dispatch!("msg_el_twice")

    assert length(Ash.read!(EventLog, authorize?: false)) == 1
  end

  test "a failed event-log write never stops the fanout (telemetry carries it)" do
    test_pid = self()

    :telemetry.attach_many(
      "event-log-test",
      [[:ash_hooks, :event, :record_failed]],
      fn event, _m, metadata, _c -> send(test_pid, {event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("event-log-test") end)

    endpoint!()

    Repo.query!("DROP TABLE #{@events}")

    assert {:ok, []} = dispatch!("msg_el_write_fail")

    assert_receive {[:ash_hooks, :event, :record_failed], %{event_uuid: "msg_el_write_fail"}}

    recreate_events!()
  end

  test "the log queries by type and time range with keyset pagination" do
    endpoint!()

    for i <- 1..3, do: dispatch!("msg_el_q#{i}")

    {:ok, %{records: page, next_cursor: cursor}} =
      AshHooks.OutboundEvent.list(EventLog, event_type: "order_paid", limit: 2)

    assert length(page) == 2
    assert is_binary(cursor)

    {:ok, %{records: rest, next_cursor: nil}} =
      AshHooks.OutboundEvent.list(EventLog, event_type: "order_paid", limit: 2, after: cursor)

    assert length(rest) == 1

    assert {:ok, %{records: []}} =
             AshHooks.OutboundEvent.list(EventLog,
               event_type: "order_paid",
               from: DateTime.add(DateTime.utc_now(), 60, :second)
             )

    # a to-bound alone and a both-bounds window compose too
    {:ok, %{records: to_bound}} =
      AshHooks.OutboundEvent.list(EventLog,
        event_type: "order_paid",
        to: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    assert to_bound != []

    {:ok, %{records: both_bounds}} =
      AshHooks.OutboundEvent.list(EventLog,
        event_type: "order_paid",
        from: DateTime.add(DateTime.utc_now(), -60, :second),
        to: DateTime.add(DateTime.utc_now(), 60, :second)
      )

    assert both_bounds != []

    # and an empty sweep of prune is a clean zero (a cutoff nothing meets)
    assert {:ok, 0} =
             AshHooks.OutboundEvent.prune(EventLog,
               older_than: DateTime.add(DateTime.utc_now(), -86_400, :second)
             )
  end

  test "the log prunes by its own retention" do
    endpoint!()
    dispatch!("msg_el_prune")

    Repo.query!("UPDATE #{@events} SET inserted_at = '2020-01-01T00:00:00Z'")

    assert {:ok, 1} =
             AshHooks.OutboundEvent.prune(EventLog,
               older_than: DateTime.add(DateTime.utc_now(), -1, :second)
             )

    assert Ash.read!(EventLog, authorize?: false) == []
  end

  describe "replay" do
    test "replaying one event to an endpoint that had no row creates it, id kept, who recorded" do
      original = endpoint!(:disabled)
      later = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: original.id, event_types: ["order_paid"]},
        authorize?: false
      )

      dispatch!("msg_el_replay_new")

      # the later endpoint had no subscription at the time
      assert {:ok, %{created: 1, re_sent: 0}} =
               AshHooks.OutboundEvent.replay(EventLog, later,
                 event_uuid: "msg_el_replay_new",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops-replay"
               )

      [row] = Ash.read!(Delivery, authorize?: false)
      assert row.endpoint_id == later.id
      assert row.event_uuid == "msg_el_replay_new"
      assert row.payload == @payload
      assert row.last_resend_by == "ops-replay"
    end

    test "replaying over an existing TERMINAL row re-arms it, who recorded on the row" do
      ep = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      dispatch!("msg_el_replay_term")

      Repo.query!(
        "UPDATE #{@deliveries} SET status = 'dead_letter', attempts = 2 WHERE endpoint_id = ?",
        [
          ep.id
        ]
      )

      assert {:ok, %{created: 0, re_sent: 1}} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_uuid: "msg_el_replay_term",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops-replay",
                 enqueue: fn _row, _event -> :ok end
               )

      [existing] = Ash.read!(Delivery, authorize?: false)
      row = Ash.get!(Delivery, existing.id, authorize?: false)

      assert row.status == :pending
      assert row.event_uuid == "msg_el_replay_term"
      assert row.last_resend_by == "ops-replay"
    end

    test "replaying a filter of events to one endpoint" do
      ep = endpoint!()

      for i <- 1..2, do: dispatch!("msg_el_bulk#{i}")

      dispatch!("other_type_msg")

      assert {:ok, %{created: 3, re_sent: 0}} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_type: "order_paid",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops-bulk"
               )

      rows = Ash.read!(Delivery, authorize?: false)
      assert length(rows) == 3
      assert Enum.all?(rows, &(&1.endpoint_id == ep.id))
    end

    test "replay's remaining arms: skips live rows, enqueue shapes, bounds, errors" do
      ep = endpoint!()

      # a live (pending) row is left to its schedule — skipped, not re-armed
      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      dispatch!("msg_el_live_row")

      assert {:ok, %{created: 0, re_sent: 0, skipped: 1}} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_uuid: "msg_el_live_row",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      # the {m, f} enqueue seam and a failing row create are contained
      dispatch!("msg_el_enqueue")
      fresh = endpoint!()

      assert {:ok, %{created: 1}} =
               AshHooks.OutboundEvent.replay(EventLog, fresh,
                 event_uuid: "msg_el_enqueue",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops",
                 enqueue: {__MODULE__, :replay_enqueue}
               )

      assert_received :replay_enqueued

      # a storage fault on row creation counts skipped
      Repo.query!("DROP TABLE #{@deliveries}")

      dispatch!("msg_el_fault")

      assert {:ok, %{created: 0, skipped: 1}} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_uuid: "msg_el_fault",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      recreate_deliveries!()

      # a fn enqueue seam applies
      dispatch!("msg_el_fn_enqueue")

      assert {:ok, %{created: 1}} =
               AshHooks.OutboundEvent.replay(EventLog, endpoint!(),
                 event_uuid: "msg_el_fn_enqueue",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops",
                 enqueue: fn _logged, _event -> :ok end
               )

      # a failed terminal re-arm counts skipped
      terminal_ep = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: terminal_ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      dispatch!("msg_el_rearm_fail")

      Repo.query!("UPDATE #{@deliveries} SET status = 'dead_letter' WHERE endpoint_id = ?", [
        terminal_ep.id
      ])

      Repo.query!("""
      CREATE TRIGGER replay_rearm_abort
      BEFORE UPDATE ON #{@deliveries}
      WHEN NEW.status = 'pending' AND OLD.status = 'dead_letter'
      BEGIN
        SELECT RAISE(ABORT, 'forced replay re-arm rejection');
      END
      """)

      assert {:ok, %{created: 0, re_sent: 0, skipped: 1}} =
               AshHooks.OutboundEvent.replay(EventLog, terminal_ep,
                 event_uuid: "msg_el_rearm_fail",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      Repo.query!("DROP TRIGGER IF EXISTS replay_rearm_abort")

      # a single-uuid read failure surfaces
      Repo.query!("DROP TABLE #{@events}")

      assert {:error, %Ash.Error.Unknown{}} =
               AshHooks.OutboundEvent.replay(EventLog, terminal_ep,
                 event_uuid: "msg_el_read_fail",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      recreate_events!()

      # filter arms: to-bound alone, both bounds, and the named errors
      dispatch!("msg_el_bounds")

      assert {:ok, %{created: created}} =
               AshHooks.OutboundEvent.replay(EventLog, endpoint!(),
                 event_type: "order_paid",
                 from: DateTime.add(DateTime.utc_now(), -60, :second),
                 to: DateTime.add(DateTime.utc_now(), 60, :second),
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      assert created >= 1

      assert {:ok, %{created: 0}} =
               AshHooks.OutboundEvent.replay(EventLog, endpoint!(),
                 event_type: "no.events.of.this.type",
                 limit: 1,
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      assert {:error, :event_filter_required} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      assert {:error, :invalid_limit} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_type: "order_paid",
                 limit: 5_000,
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )

      assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_type: "order_paid",
                 requested_by: "ops"
               )
    end

    test "prune's remaining arms: exhaustion, batch cap, and the read error" do
      endpoint!()

      for i <- 1..3, do: dispatch!("msg_el_prune#{i}")

      Repo.query!("UPDATE #{@events} SET inserted_at = '2020-01-01T00:00:00Z'")

      # batching walks to exhaustion
      assert {:ok, 3} =
               AshHooks.OutboundEvent.prune(EventLog,
                 older_than: DateTime.utc_now(),
                 batch_size: 2
               )

      assert {:error, :invalid_batch_size} =
               AshHooks.OutboundEvent.prune(EventLog,
                 older_than: DateTime.utc_now(),
                 batch_size: 0
               )

      Repo.query!("DROP TABLE #{@events}")

      assert {:error, %Ash.Error.Unknown{}} =
               AshHooks.OutboundEvent.prune(EventLog, older_than: DateTime.utc_now())

      assert {:error, %Ash.Error.Unknown{}} = AshHooks.OutboundEvent.list(EventLog)
      recreate_events!()
    end

    def replay_enqueue(_logged, _event) do
      send(self(), :replay_enqueued)
      :ok
    end

    test "replay requires requested_by and names missing events" do
      ep = endpoint!()

      assert {:error, :requested_by_required} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_uuid: "x",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint
               )

      assert {:error, :event_not_found} =
               AshHooks.OutboundEvent.replay(EventLog, ep,
                 event_uuid: "msg_el_absent",
                 deliveries: Delivery,
                 declaration: {Emitter, :order_paid},
                 endpoints: Endpoint,
                 requested_by: "ops"
               )
    end
  end

  defp recreate_deliveries! do
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
      endpoint_snapshot TEXT,
      resend_baseline INTEGER NOT NULL DEFAULT 0,
      resend_count INTEGER NOT NULL DEFAULT 0,
      last_resend_by TEXT, last_resend_at TEXT,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )
  end

  defp recreate_events! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@events} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      version INTEGER, payload BLOB NOT NULL,
      inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@events}_unique_event_index ON #{@events} (event_uuid)"
    )
  end

  @tag release_fix: 2
  test "release missing-row replay binds its declaration and stores its requester" do
    endpoint = endpoint!()
    {:ok, []} = dispatch!("release-missing-replay")

    assert {:ok, %{created: 1}} =
             AshHooks.OutboundEvent.replay(EventLog, endpoint,
               event_uuid: "release-missing-replay",
               deliveries: Delivery,
               endpoints: Endpoint,
               declaration: {Emitter, :order_paid},
               requested_by: "operator",
               enqueue: {__MODULE__, :capture_replay}
             )

    assert_receive {:release_replay, %Delivery{} = row, %AshHooks.Event{} = event}
    assert row.dispatch_source == AshHooks.OutboundBinding.source(Emitter, :order_paid, Endpoint)
    assert row.dispatch_route == AshHooks.OutboundBinding.named_route(__MODULE__, :capture_replay)
    assert row.last_resend_by == "operator"
    assert row.last_resend_at != nil
    assert {event.id, event.type, event.payload} == {row.event_uuid, row.event_type, row.payload}
  end

  def capture_replay(row, event) do
    send(self(), {:release_replay, row, event})
    :ok
  end

  defmodule TenantLog do
    use Ash.Resource,
      domain: AshHooks.EventLogTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundEvent]

    sqlite do
      table "event_log_tenant_events"
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute :org_id, :string, allow_nil?: false
      timestamps()
    end

    multitenancy do
      strategy :attribute
      attribute :org_id
    end

    actions do
      defaults [:read]
    end
  end

  defmodule MismatchedEmitter do
    use Ash.Resource, domain: AshHooks.EventLogTest.Domain, extensions: [AshHooks]

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.EventLogTest.Subscription)
        deliveries(AshHooks.EventLogTest.Delivery)
        events(AshHooks.EventLogTest.TenantLog)
      end
    end
  end

  @tag release_fix: 9
  test "release dispatch validates the optional event log before reads or writes" do
    {:ok, event} = AshHooks.Event.new(type: :order_paid, payload: @payload)
    assert {:error, :tenancy_mismatch} = AshHooks.dispatch(MismatchedEmitter, :order_paid, event)
  end

  @tag release_fix: 9
  test "release delivery execution validates optional history" do
    config = [
      deliveries: Delivery,
      endpoints: Endpoint,
      attempts: TenantLog,
      secret_resolver: fn _ -> {:error, :missing} end
    ]

    assert {:error, :tenancy_mismatch} =
             AshHooks.Delivery.run(
               %{"endpoint_id" => Ash.UUID.generate(), "event_uuid" => "missing"},
               config
             )
  end

  @tag release_fix: 9
  test "release pruning validates optional history" do
    assert {:error, :tenancy_mismatch} =
             AshHooks.Delivery.prune(Delivery,
               attempts: TenantLog,
               older_than: DateTime.utc_now()
             )
  end

  @tag release_fix: 9
  test "release test sends validate optional history before creating a delivery" do
    endpoint = endpoint!()

    assert {:error, :tenancy_mismatch} =
             AshHooks.Delivery.test_send(endpoint,
               type: :order_paid,
               deliveries: Delivery,
               attempts: TenantLog,
               secret_resolver: fn _ -> {:error, :missing} end
             )

    assert Ash.read!(Delivery, authorize?: false) == []
  end

  @tag release_fix: 9
  test "release replay validates its configured delivery and endpoint resources" do
    endpoint = endpoint!()
    {:ok, []} = dispatch!("release-replay-tenancy-set")

    assert {:error, :tenancy_mismatch} =
             AshHooks.OutboundEvent.replay(EventLog, endpoint,
               deliveries: TenantLog,
               endpoints: Endpoint,
               event_uuid: "release-replay-tenancy-set",
               requested_by: "operator"
             )
  end

  @tag release_fix: 13
  test "release event-log dry run counts its batch without creating deliveries" do
    endpoint = endpoint!()
    for id <- ["dry-run-one", "dry-run-two"], do: dispatch!(id)

    assert {:ok, %{count: 1}} =
             AshHooks.OutboundEvent.replay(EventLog, endpoint,
               event_type: "order_paid",
               deliveries: Delivery,
               endpoints: Endpoint,
               declaration: {Emitter, :order_paid},
               requested_by: "operator",
               dry_run: true,
               limit: 1
             )

    assert Ash.read!(Delivery, authorize?: false) == []
  end

  @tag release_fix: 14
  test "release event-log replay spaces its configured batches by a second" do
    endpoint = endpoint!()
    for id <- ["rate-one", "rate-two"], do: dispatch!(id)

    callback = fn _, _ ->
      send(self(), {:replay_tick, System.monotonic_time(:millisecond)})
      :ok
    end

    assert {:ok, %{created: 2}} =
             AshHooks.OutboundEvent.replay(EventLog, endpoint,
               event_type: "order_paid",
               deliveries: Delivery,
               endpoints: Endpoint,
               declaration: {Emitter, :order_paid},
               requested_by: "operator",
               per_second: 1,
               enqueue: callback
             )

    assert_received {:replay_tick, first}
    assert_received {:replay_tick, second}
    assert second - first >= 1_000
  end
end
