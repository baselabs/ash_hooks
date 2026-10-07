defmodule AshHooks.ReconcileTest do
  @moduledoc """
  SQLite checks for recovery candidate selection, tenant scope, route binding,
  active enqueue leases, and the custom callback contract. Concurrent persisted
  job admission and receiver effects are exercised on real PostgreSQL/Oban in
  OutboundPostgresReadinessTest. A released lease permits later recovery calls;
  custom enqueue callbacks must be idempotent.
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
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT,
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
        signing_mode: :standard,
        dispatch_source: AshHooks.OutboundBinding.source(Emitter, :order_paid, Endpoint)
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

  def enqueue_must_not_run(_delivery, _event), do: raise("enqueue must not run")

  test "a stranded pending row is lease-claimed, enqueued, and reported reconciled" do
    stranded_row!("org_a", "rec-1")

    assert {:ok, results} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-test",
               enqueue: counting_enqueuer(self())
             )

    assert [%{status: :reconciled, error: nil}] = results
    assert_received {:enqueued, "rec-1"}

    # The enqueue lease is released after durable admission; the delivery
    # state remains pending for the worker to claim.
    row = row_state!("rec-1", "org_a")
    assert row.status == :pending
    assert row.enqueue_token == nil
  end

  test "recovery admits every due state and preserves future retry and live-send windows" do
    for uuid <- [
          "rec-state-pending",
          "rec-state-enqueue-failed",
          "rec-state-retry-due",
          "rec-state-retry-future",
          "rec-state-send-expired",
          "rec-state-send-live",
          "rec-state-disable"
        ] do
      stranded_row!("org_a", uuid)
    end

    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    past = DateTime.add(now, -120, :second) |> DateTime.to_iso8601()
    future = DateTime.add(now, 120, :second) |> DateTime.to_iso8601()

    Repo.query!("UPDATE #{@deliveries} SET status = 'enqueue_failed' WHERE event_uuid = ?", [
      "rec-state-enqueue-failed"
    ])

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ? WHERE event_uuid = ?",
      [past, "rec-state-retry-due"]
    )

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ? WHERE event_uuid = ?",
      [future, "rec-state-retry-future"]
    )

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'sending', attempts = 2, attempt_token = ?, send_lease_expires_at = ? WHERE event_uuid = ?",
      [Ash.UUID.generate(), past, "rec-state-send-expired"]
    )

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'sending', attempts = 2, attempt_token = ?, send_lease_expires_at = ? WHERE event_uuid = ?",
      [Ash.UUID.generate(), future, "rec-state-send-live"]
    )

    Repo.query!("UPDATE #{@deliveries} SET status = 'disable_pending' WHERE event_uuid = ?", [
      "rec-state-disable"
    ])

    assert {:ok, results} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-states",
               enqueue: counting_enqueuer(self())
             )

    assert Enum.all?(results, &(&1.status == :reconciled))
    assert length(results) == 5

    enqueued =
      for _ <- 1..5 do
        assert_receive {:enqueued, uuid}, 1_000
        uuid
      end

    assert Enum.sort(enqueued) ==
             Enum.sort([
               "rec-state-pending",
               "rec-state-enqueue-failed",
               "rec-state-retry-due",
               "rec-state-send-expired",
               "rec-state-disable"
             ])

    refute_receive {:enqueued, _}, 100

    assert row_state!("rec-state-retry-future", "org_a").status == :failed_retryable
    assert row_state!("rec-state-send-live", "org_a").status == :sending
    assert row_state!("rec-state-retry-due", "org_a").attempts == 1
    assert row_state!("rec-state-send-expired", "org_a").attempts == 2
  end

  test "a due failed_retryable row re-admitted by recovery KEEPS its last_error diagnostic" do
    # The sirtify-routed finding (claude F8, 2026-10-06): recovery re-admission is a
    # TRANSPORT event, not a delivery outcome — wiping the row's failure diagnostic on
    # re-admission hides why the retry was scheduled until a new outcome lands.
    stranded_row!("org_a", "rec-diag-retry")

    past =
      DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -120, :second)
      |> DateTime.to_iso8601()

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ?, last_error = 'http_503' WHERE event_uuid = ?",
      [past, "rec-diag-retry"]
    )

    assert {:ok, [result]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-diag",
               enqueue: counting_enqueuer(self())
             )

    assert result.status == :reconciled
    assert_receive {:enqueued, "rec-diag-retry"}, 1_000

    row = row_state!("rec-diag-retry", "org_a")
    assert row.status == :failed_retryable
    assert row.attempts == 1
    assert row.last_error == "http_503", "re-admission must not wipe the failure diagnostic"
  end

  test "a terminal outcome releases the enqueue claim — a stale reconciler release no-ops, never clobbers the terminal diagnostic" do
    # The 2.0.3 review's stale-replay finding, at its root: mark_succeeded and
    # mark_send_failed used to leave a reconciler's enqueue_token live on terminal
    # rows, so the token-gated release could still fire AFTER the worker completed
    # and overwrite the terminal diagnostic (endpoint_disabled) with the stale
    # pre-admission one (http_503).
    stranded_row!("org_a", "rec-terminal-claim")
    token = Ash.UUID.generate()
    lease = DateTime.add(DateTime.utc_now(), 30, :second) |> DateTime.to_iso8601()

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ?, last_error = 'http_503', enqueue_token = ?, enqueue_lease_expires_at = ? WHERE event_uuid = ?",
      [
        DateTime.add(DateTime.utc_now(), -120, :second) |> DateTime.to_iso8601(),
        token,
        lease,
        "rec-terminal-claim"
      ]
    )

    row = row_state!("rec-terminal-claim", "org_a")

    # The worker's terminal transition (dead_letter) both writes the outcome AND
    # releases the enqueue claim in the same statement.
    row
    |> Ash.Changeset.for_update(
      :mark_send_failed,
      %{
        error: "endpoint_disabled",
        next_attempt_at: nil,
        dead_letter?: true,
        response_status: nil,
        response_snippet: nil
      },
      tenant: "org_a",
      authorize?: false
    )
    |> Ash.update!()

    terminal = row_state!("rec-terminal-claim", "org_a")
    assert terminal.status == :dead_letter
    assert terminal.last_error == "endpoint_disabled"
    assert is_nil(terminal.enqueue_token), "the terminal outcome must release the enqueue claim"
    assert is_nil(terminal.enqueue_lease_expires_at)

    # mark_succeeded releases the claim the same way.
    stranded_row!("org_a", "rec-terminal-claim-ok")
    ok_token = Ash.UUID.generate()

    Repo.query!(
      "UPDATE #{@deliveries} SET enqueue_token = ?, enqueue_lease_expires_at = ? WHERE event_uuid = ?",
      [ok_token, lease, "rec-terminal-claim-ok"]
    )

    row_state!("rec-terminal-claim-ok", "org_a")
    |> Ash.Changeset.for_update(:mark_succeeded, %{response_status: 200, response_snippet: nil},
      tenant: "org_a",
      authorize?: false
    )
    |> Ash.update!()

    ok = row_state!("rec-terminal-claim-ok", "org_a")
    assert ok.status == :succeeded
    assert is_nil(ok.enqueue_token)
  end

  test "a terminal completion between claim and release reports :reconciled, never :endpoint_error (benign completion)" do
    # Round-2 finding 2: the terminal outcome clears the enqueue claim, so the
    # release matches zero rows — that is the worker having ALREADY finished the
    # row, which is success-shaped, not a release failure.
    stranded_row!("org_a", "rec-benign-race")

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    past = DateTime.add(now, -120, :second) |> DateTime.to_iso8601()

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ?, last_error = 'http_503' WHERE event_uuid = ?",
      [past, "rec-benign-race"]
    )

    # The enqueuer SIMULATES the race: the row is terminally completed inside
    # the enqueue callback, before the dispatcher's release fires.
    row = row_state!("rec-benign-race", "org_a")

    completing_enqueuer = fn _delivery, _event ->
      row
      |> Ash.Changeset.for_update(:mark_succeeded, %{response_status: 200, response_snippet: nil},
        tenant: "org_a",
        authorize?: false
      )
      |> Ash.update!()

      :ok
    end

    assert {:ok, [result]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-benign",
               enqueue: completing_enqueuer
             )

    assert result.status == :reconciled, "outcome-driven claim invalidation is benign completion"

    final = row_state!("rec-benign-race", "org_a")
    assert final.status == :succeeded
    assert is_nil(final.enqueue_token)
  end

  test "a stored 410 obligation keeps gone_410 through a stale release (round-2 finding 1)" do
    stranded_row!("org_a", "rec-410-claim")

    Repo.query!(
      "UPDATE #{@deliveries} SET last_error = 'http_503', enqueue_token = ?, enqueue_lease_expires_at = ? WHERE event_uuid = ?",
      [
        Ash.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 30, :second) |> DateTime.to_iso8601(),
        "rec-410-claim"
      ]
    )

    row_state!("rec-410-claim", "org_a")
    |> Ash.Changeset.for_update(
      :mark_disable_pending,
      %{
        response_status: 410,
        response_snippet: nil,
        endpoint_snapshot: %{"endpoint_pk" => %{}}
      },
      tenant: "org_a",
      authorize?: false
    )
    |> Ash.update!()

    stored = row_state!("rec-410-claim", "org_a")
    assert stored.status == :disable_pending
    assert stored.last_error == "gone_410"
    assert is_nil(stored.enqueue_token), "the obligation releases the claim at storage"
  end

  test "a genuinely foreign live claim at release still reports :stale_enqueue_claim (:endpoint_error)" do
    # The benign-completion classification must NOT swallow a real contention:
    # if a THIRD claimant re-claimed the row between our claim and our release,
    # the reload finds a live foreign token — a genuine stale claim, surfaced as
    # :endpoint_error (the reconcile caller's failure vocabulary).
    stranded_row!("org_a", "rec-foreign-claim")

    past =
      DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -120, :second)
      |> DateTime.to_iso8601()

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ?, last_error = 'http_503' WHERE event_uuid = ?",
      [past, "rec-foreign-claim"]
    )

    row = row_state!("rec-foreign-claim", "org_a")

    # The enqueuer simulates a racing re-claimant: it stamps a FRESH foreign
    # claim on the row inside the callback, before our release fires.
    foreign_enqueuer = fn delivery, _event ->
      foreign_token = Ash.UUID.generate()
      foreign_lease = DateTime.add(DateTime.utc_now(), 30, :second) |> DateTime.to_iso8601()

      Repo.query!(
        "UPDATE #{@deliveries} SET enqueue_token = ?, enqueue_lease_expires_at = ? WHERE event_uuid = ?",
        [foreign_token, foreign_lease, delivery.event_uuid]
      )

      :ok
    end

    assert {:ok, [result]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-foreign",
               enqueue: foreign_enqueuer
             )

    assert result.status == :endpoint_error
  end

  test "a parked lease fences immediate re-admission — the forced interleaving, not scheduling luck (round-3)" do
    # Round-3 finding 1: the parked lease must actually GATE the next claim
    # (the claim gate is the lease alone now) — admitted once, then fenced
    # until the horizon passes, then claimable again.
    stranded_row!("org_a", "rec-park-fence")

    past =
      DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -120, :second)
      |> DateTime.to_iso8601()

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ?, last_error = 'http_503' WHERE event_uuid = ?",
      [past, "rec-park-fence"]
    )

    parent = self()

    assert {:ok, [%{status: :reconciled}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-park",
               enqueue: fn delivery, _event ->
                 send(parent, {:parked, delivery.event_uuid})
                 :ok
               end
             )

    assert_receive {:parked, "rec-park-fence"}

    row = row_state!("rec-park-fence", "org_a")
    assert row.last_error == "http_503", "the diagnostic survives the admitted re-enqueue"
    assert is_nil(row.enqueue_token), "the claim is released"
    assert not is_nil(row.enqueue_lease_expires_at), "the lease is PARKED"
    assert DateTime.compare(row.enqueue_lease_expires_at, DateTime.utc_now()) == :gt

    # The immediate second sweep finds the row fenced: the lease gate blocks
    # the claim, the row surfaces as a contended :duplicate (the concurrent
    # race outcome vocabulary), and the seam is NEVER called again.
    assert {:ok, [%{status: :duplicate}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-park",
               enqueue: fn delivery, _event ->
                 send(parent, {:again, delivery.event_uuid})
                 :ok
               end
             )

    refute_receive {:again, _}, 200

    # Once the horizon passes, the row is claimable again (crashed-claim and
    # parked-release recovery share the one gate).
    Repo.query!(
      "UPDATE #{@deliveries} SET enqueue_lease_expires_at = ? WHERE event_uuid = ?",
      [DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601(), "rec-park-fence"]
    )

    assert {:ok, [%{status: :reconciled}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-park",
               enqueue: fn delivery, _event ->
                 send(parent, {:unfenced, delivery.event_uuid})
                 :ok
               end
             )

    assert_receive {:unfenced, "rec-park-fence"}
  end

  test "a row deleted between claim and release reports :enqueue_reload_failed (its own label, never a stale claim)" do
    # The classification split: a vanished/unreadable row is distinguishable
    # from genuine contention in the result vocabulary.
    stranded_row!("org_a", "rec-vanished")

    past =
      DateTime.add(DateTime.utc_now() |> DateTime.truncate(:second), -120, :second)
      |> DateTime.to_iso8601()

    Repo.query!(
      "UPDATE #{@deliveries} SET status = 'failed_retryable', attempts = 1, next_attempt_at = ?, last_error = 'http_503' WHERE event_uuid = ?",
      [past, "rec-vanished"]
    )

    vanishing_enqueuer = fn delivery, _event ->
      Repo.query!("DELETE FROM #{@deliveries} WHERE event_uuid = ?", [delivery.event_uuid])
      :ok
    end

    assert {:ok, [result]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-vanished",
               enqueue: vanishing_enqueuer
             )

    assert result.status == :endpoint_error
    assert inspect(result.error) =~ "enqueue_reload_failed"
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
        enqueue_key: "reconcile-test",
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

    # Every lease was released after the one admitted enqueue.
    for i <- 1..5 do
      row = row_state!("rec-race-#{i}", "org_a")
      assert row.status == :pending
      assert row.enqueue_token == nil
    end
  end

  test "a re-dispatch after reconciliation converges through the repair path — the seam's idempotency is the cross-mechanism contract" do
    stranded_row!("org_a", "rec-repair")

    Ash.create!(Subscription, %{event_types: ["*"], endpoint_id: endpoint_id("org_a")},
      tenant: "org_a",
      authorize?: false
    )

    # Reconcile first: leases + enqueues once and leaves the delivery pending.
    assert {:ok, [%{status: :reconciled}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-test",
               enqueue: counting_enqueuer(self())
             )

    # ...then a NORMAL re-dispatch of the same event: the repair path
    # claims the marked row and enqueues AGAIN. This is the documented
    # boundary, not a defect: cross-mechanism exactly-once is the SEAM's
    # contract — the canonical Oban seam's uniqueness makes the second
    # Custom callbacks need idempotency across later recovery calls.
    # Live enqueue leases serialize active admission.
    event = %AshHooks.Event{type: "order_paid", payload: @payload, id: "rec-repair"}

    assert {:ok, [%{status: :duplicate}]} =
             Dispatcher.dispatch(Emitter, :order_paid, event,
               tenant: "org_a",
               enqueue_key: "reconcile-test",
               enqueue: counting_enqueuer(self())
             )

    assert_received {:enqueued, "rec-repair"}
    refute_received {:enqueued, "rec-repair"}

    # The pending row is still ready for the admitted trigger.
    assert row_state!("rec-repair", "org_a").status == :pending
  end

  test "a failing enqueue releases its lease and records the bounded error" do
    stranded_row!("org_a", "rec-fail")

    assert {:ok, results} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-test",
               enqueue: fn _delivery, _event -> {:error, "queue down"} end
             )

    # Arbitrary callback strings become a fixed contents-free classification.
    assert [%{status: :enqueue_failed, error: "unclassified"}] = results
    row = row_state!("rec-fail", "org_a")
    assert row.status == :pending
    assert row.enqueue_token == nil
    assert row.last_error == "unclassified"
  end

  test "a missing enqueue callback leaves pending rows unresolved" do
    stranded_row!("org_a", "rec-defer")

    assert {:ok, [%{status: :enqueue_failed, error: :unresolved_route}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff()
             )

    refute_received {:enqueued, _}
    assert row_state!("rec-defer", "org_a").status == :pending
  end

  test "an unkeyed or different stored route is rejected before enqueue" do
    for {uuid, stored_route, expected} <- [
          {"rec-unkeyed-route", AshHooks.OutboundBinding.unkeyed_route(), :unresolved_route},
          {"rec-different-route",
           AshHooks.OutboundBinding.named_route(__MODULE__, :different_enqueue),
           :dispatch_route_conflict}
        ] do
      stranded_row!("org_a", uuid)

      Repo.query!("UPDATE #{@deliveries} SET dispatch_route = ? WHERE event_uuid = ?", [
        stored_route,
        uuid
      ])

      assert {:ok, [%{status: :enqueue_failed, error: ^expected}]} =
               Dispatcher.reconcile_pending(Emitter, :order_paid,
                 tenant: "org_a",
                 older_than: cutoff(),
                 enqueue: {__MODULE__, :enqueue_must_not_run}
               )

      Repo.query!("DELETE FROM #{@deliveries}")
    end
  end

  test "a live enqueue lease is reported as contended before enqueue" do
    uuid = "rec-live-enqueue-lease"
    stranded_row!("org_a", uuid)
    route = AshHooks.OutboundBinding.named_route(__MODULE__, :enqueue_must_not_run)
    future = DateTime.add(DateTime.utc_now(), 120, :second) |> DateTime.to_iso8601()

    Repo.query!(
      "UPDATE #{@deliveries} SET dispatch_route = ?, enqueue_token = ?, enqueue_lease_expires_at = ? WHERE event_uuid = ?",
      [route, Ash.UUID.generate(), future, uuid]
    )

    assert {:ok, [%{status: :duplicate, error: :enqueue_contended}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue: {__MODULE__, :enqueue_must_not_run}
             )
  end

  test "reconcile is tenant-scoped: org_a's sweep never claims org_b's stranded row" do
    # attacker's stranded row FIRST
    stranded_row!("org_b", "rec-theirs")
    stranded_row!("org_a", "rec-ours")

    assert {:ok, [%{endpoint_id: _ours}]} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-test",
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
      "INSERT INTO #{@deliveries} (id, event_uuid, event_type, payload, endpoint_id, signing_mode, dispatch_source, status, attempts, org_id, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, 'pending', 0, 'org_a', ?, ?)",
      [
        Ash.UUID.generate(),
        "",
        "order_paid",
        @payload,
        endpoint_id("org_a"),
        "standard",
        AshHooks.OutboundBinding.source(Emitter, :order_paid, Endpoint),
        DateTime.to_iso8601(stale()),
        DateTime.to_iso8601(stale())
      ]
    )

    assert {:ok, results} =
             Dispatcher.reconcile_pending(Emitter, :order_paid,
               tenant: "org_a",
               older_than: cutoff(),
               enqueue_key: "reconcile-test",
               enqueue: counting_enqueuer(self())
             )

    assert [%{status: :enqueue_failed, error: "event id must not be empty"}] = results
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
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT,
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
