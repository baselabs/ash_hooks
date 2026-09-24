defmodule AshHooks.ReconcileTest do
  @moduledoc """
  The orphan-pending reconciliation (D8): delivery rows stranded at
  `:pending` by a crash between the row write and the enqueue are claimed
  by a WHERE-gated CAS on `:mark_enqueue_failed` (a REAL state flip —
  matched-records is the win signal) and driven through the same enqueue
  seam dispatch takes. The race proof uses a CUSTOM (non-Oban) counting
  enqueuer so Oban uniqueness cannot mask the CAS: concurrent reconcilers
  enqueue each stranded row EXACTLY ONCE.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.ReconcileTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("reconcile_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.ReconcileTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("reconcile_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
      timestamps()
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.ReconcileTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("reconcile_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.ReconcileTest.Endpoint)
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.ReconcileTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("reconcile_test_emitters")
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
        subscriptions(AshHooks.ReconcileTest.Subscription)
        deliveries(AshHooks.ReconcileTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.ReconcileTest.Endpoint)
      resource(AshHooks.ReconcileTest.Subscription)
      resource(AshHooks.ReconcileTest.Delivery)
      resource(AshHooks.ReconcileTest.Emitter)
    end
  end

  use ExUnit.Case, async: false

  require Ash.Query

  alias AshHooks.Dispatcher
  alias AshHooks.Test.Repo

  @deliveries "reconcile_test_deliveries"
  @endpoints "reconcile_test_endpoints"
  @subscriptions "reconcile_test_subscriptions"
  @payload Jason.encode!(%{"order" => 1})

  setup_all do
    create_tables!()

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

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
      legacy_previous_secret_ref TEXT,
      org_id TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY,
      event_types TEXT NOT NULL,
      endpoint_id TEXT NOT NULL,
      signing_mode TEXT,
      org_id TEXT NOT NULL
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
      org_id TEXT NOT NULL,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (org_id, endpoint_id, event_uuid)"
    )
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")

    # attacker-tenant endpoint first (adversarial ordering), then the
    # tenant under test
    for org <- ["org_b", "org_a"] do
      Ash.create!(Endpoint, %{url: "https://#{org}.test/hook", secret_ref: "ref-" <> org},
        tenant: org,
        authorize?: false
      )
    end

    :ok
  end

  defp endpoint_id(org) do
    Endpoint
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read_one!(authorize?: false, tenant: org)
    |> Map.fetch!(:id)
  end

  # run-time staleness: 10 minutes back, explicit margins everywhere (a
  # compile-time constant drifts against the run-time cutoff and lands
  # boundary-exact — the span rule)
  defp stale do
    DateTime.add(DateTime.utc_now(), -600, :second) |> DateTime.truncate(:microsecond)
  end

  defp cutoff do
    DateTime.add(DateTime.utc_now(), -300, :second) |> DateTime.truncate(:microsecond)
  end

  # a stranded row: created (and tenant-stamped) far in the past, never enqueued
  defp stranded_row!(org, uuid) do
    Ash.create!(
      Delivery,
      %{
        event_uuid: uuid,
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: endpoint_id(org),
        signing_mode: :standard
      },
      action: :dispatch,
      tenant: org,
      authorize?: false
    )

    backdate = stale()

    Repo.query!(
      "UPDATE #{@deliveries} SET inserted_at = ?, updated_at = ? WHERE event_uuid = ?",
      [
        DateTime.to_iso8601(backdate),
        DateTime.to_iso8601(backdate),
        uuid
      ]
    )
  end

  defp row_state!(uuid, org) do
    Delivery
    |> Ash.Query.filter(event_uuid == ^uuid)
    |> Ash.read_one!(authorize?: false, tenant: org)
  end

  # a CUSTOM enqueue seam (non-Oban by construction): records each
  # invocation so the exactly-once property is asserted on the SEAM, not
  # masked by job uniqueness
  defp counting_enqueuer(collector) do
    fn delivery, _event ->
      send(collector, {:enqueued, delivery.event_uuid})
      :ok
    end
  end

  test "a stranded :pending row is CAS-flipped, enqueued, and reported :reconciled" do
    stranded_row!("org_a", "rec-1")

    assert {:ok, results} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue: counting_enqueuer(self())
             )

    assert [%{status: :reconciled, error: nil}] = results
    assert_received {:enqueued, "rec-1"}

    # the winner stays :enqueue_failed (one-shot per reconcile run: a
    # concurrent reconciler cannot re-claim it), carrying the claim marker
    row = row_state!("rec-1", "org_a")
    assert row.status == :enqueue_failed
    assert row.last_error == "reconcile_pending"
  end

  test "the cutoff gates the claim: fresh rows are left alone" do
    stranded_row!("org_a", "rec-fresh")
    # ...but backdate only 1 second — inside the default 5-minute cutoff
    Repo.query!(
      "UPDATE #{@deliveries} SET inserted_at = ?, updated_at = ? WHERE event_uuid = ?",
      [
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1, :second)),
        DateTime.to_iso8601(DateTime.add(DateTime.utc_now(), -1, :second)),
        "rec-fresh"
      ]
    )

    assert {:ok, []} = Dispatcher.reconcile_pending(Emitter, :order_paid, tenant: "org_a")
    assert row_state!("rec-fresh", "org_a").status == :pending
  end

  test "concurrent reconcilers enqueue each stranded row EXACTLY ONCE (custom seam — Oban uniqueness cannot mask the CAS)" do
    for i <- 1..5, do: stranded_row!("org_a", "rec-race-#{i}")

    parent = self()
    enqueuer = counting_enqueuer(parent)

    reconciler = fn ->
      Dispatcher.reconcile_pending(Emitter, :order_paid,
        tenant: "org_a",
        older_than: cutoff(),
        enqueue: enqueuer
      )
    end

    # N concurrent reconcilers race for the same 5 rows (the sqlite pool
    # serializes statements; the CAS decides the winner set either way)
    tasks = for _ <- 1..4, do: Task.async(reconciler)
    results = Task.await_many(tasks, 10_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    # every row enqueued EXACTLY once across all winners
    enqueued =
      for _ <- 1..5 do
        receive do
          {:enqueued, uuid} -> uuid
        after
          1_000 -> flunk("expected exactly 5 enqueues")
        end
      end

    assert Enum.sort(enqueued) == Enum.sort(for i <- 1..5, do: "rec-race-#{i}")

    refute_receive {:enqueued, _}, 100

    # and every stranded row was claimed exactly once — :enqueue_failed
    # with the marker, never re-claimable by another reconciler
    for i <- 1..5 do
      row = row_state!("rec-race-#{i}", "org_a")
      assert row.status == :enqueue_failed
      assert row.last_error == "reconcile_pending"
    end
  end

  test "a re-dispatch after reconciliation converges through the repair path — the seam's idempotency is the cross-mechanism contract" do
    stranded_row!("org_a", "rec-repair")

    Ash.create!(Subscription, %{event_types: ["*"], endpoint_id: endpoint_id("org_a")},
      tenant: "org_a",
      authorize?: false
    )

    # reconcile first: claims + enqueues once (row left :enqueue_failed,
    # marked — one-shot per reconcile run)
    assert {:ok, [%{status: :reconciled}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue: counting_enqueuer(self())
             )

    # ...then a NORMAL re-dispatch of the same event: the repair path
    # claims the marked row and enqueues AGAIN. This is the documented
    # boundary, not a defect: cross-mechanism exactly-once is the SEAM's
    # contract — the canonical Oban seam's uniqueness makes the second
    # enqueue a conflict (:ok, effect-once, proven in worker_test); a
    # custom seam must be idempotent itself (each mechanism claims the
    # row at most once — the CAS guarantee this suite proves).
    event = %AshHooks.Event{type: "order_paid", payload: @payload, id: "rec-repair"}

    assert {:ok, [%{status: :created}]} =
             Dispatcher.dispatch(Emitter, :order_paid, event,
               tenant: "org_a",
               enqueue: counting_enqueuer(self())
             )

    assert_received {:enqueued, "rec-repair"}
    assert_received {:enqueued, "rec-repair"}

    # the repair requeue moved the row back to :pending for the runtime
    assert row_state!("rec-repair", "org_a").status == :pending
  end

  test "the design's test-9 race: concurrent reconcilers each claim a row AT MOST ONCE (the CAS bound)" do
    for i <- 1..5, do: stranded_row!("org_a", "rec-mixed-#{i}")

    parent = self()
    enqueuer = counting_enqueuer(parent)

    reconciler = fn ->
      Dispatcher.reconcile_pending(Emitter, :order_paid,
        tenant: "org_a",
        older_than: cutoff(),
        enqueue: enqueuer
      )
    end

    reconcilers = for _ <- 1..6, do: Task.async(reconciler)
    results = Task.await_many(reconcilers, 10_000)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    # exactly one enqueue per row across ALL reconcilers — matched-records
    # is the win signal and :enqueue_failed is one-shot
    enqueued =
      for _ <- 1..5 do
        receive do
          {:enqueued, uuid} -> uuid
        after
          1_000 -> flunk("expected exactly 5 enqueues")
        end
      end

    assert Enum.sort(enqueued) == Enum.sort(for i <- 1..5, do: "rec-mixed-#{i}")
    refute_receive {:enqueued, _}, 100
  end

  test "a failing enqueue leaves the row :enqueue_failed for the repair path and reports the failure" do
    stranded_row!("org_a", "rec-fail")

    assert {:ok, results} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue: fn _delivery, _event -> {:error, "queue down"} end
             )

    # the seam's arbitrary string classifies through the bounded grammar
    # (the ledger floor — never raw consumer terms)
    assert [%{status: :enqueue_failed, error: "unclassified"}] = results
    assert row_state!("rec-fail", "org_a").status == :enqueue_failed
  end

  test "a nil seam defers: rows are CAS-flipped for the re-dispatch repair path, nothing enqueued" do
    stranded_row!("org_a", "rec-defer")

    assert {:ok, [%{status: :deferred}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff()
             )

    refute_received {:enqueued, _}
    assert row_state!("rec-defer", "org_a").status == :enqueue_failed
  end

  test "reconcile is tenant-scoped: org_a's sweep never claims org_b's stranded row" do
    # attacker's stranded row FIRST
    stranded_row!("org_b", "rec-theirs")
    stranded_row!("org_a", "rec-ours")

    assert {:ok, [%{endpoint_id: _ours}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue: counting_enqueuer(self())
             )

    assert_received {:enqueued, "rec-ours"}
    refute_received {:enqueued, "rec-theirs"}

    assert row_state!("rec-theirs", "org_b").status == :pending
  end

  test "a stranded row whose event fields no longer build a valid event reports :enqueue_failed — the seam never sees a broken event" do
    # a blank event_uuid passes the storage layer but fails Event.new —
    # reconciliation surfaces it per-row instead of handing the seam junk
    Repo.query!(
      "INSERT INTO #{@deliveries} (id, event_uuid, event_type, payload, endpoint_id, signing_mode, status, attempts, org_id, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', 0, 'org_a', ?, ?)",
      [
        Ash.UUID.generate(),
        "",
        "order_paid",
        @payload,
        endpoint_id("org_a"),
        "standard",
        DateTime.to_iso8601(stale()),
        DateTime.to_iso8601(stale())
      ]
    )

    assert {:ok, results} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue: counting_enqueuer(self())
             )

    assert [%{status: :enqueue_failed, error: {:invalid_event, _}}] = results
    refute_received {:enqueued, _}
  end

  test "a CAS storage fault surfaces as {:error, _}, never a crash" do
    stranded_row!("org_a", "rec-fault")

    Repo.query!("DROP TABLE #{@deliveries}")

    assert {:error, _reason} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff()
             )
  after
    # restore the fixture table for the file's other tests
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
      org_id TEXT NOT NULL,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (org_id, endpoint_id, event_uuid)"
    )
  end

  test "the pre-flight applies: tenant-less reconcile over multitenant rows is the named error" do
    stranded_row!("org_a", "rec-guard")

    assert {:error, :tenant_required} =
             Dispatcher.reconcile_pending(Emitter, :order_paid, older_than: cutoff())

    # and the bare 2-arity forms (the delegate's and the dispatcher's own
    # default-opts head) fail closed the same way
    assert {:error, :tenant_required} = AshHooks.reconcile_pending(Emitter, :order_paid)
    assert {:error, :tenant_required} = Dispatcher.reconcile_pending(Emitter, :order_paid)

    assert row_state!("rec-guard", "org_a").status == :pending
  end
end
