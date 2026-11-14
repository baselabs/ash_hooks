defmodule AshHooks.ResendTest do
  @moduledoc """
  Resend and bulk replay: a resend re-arms a TERMINAL delivery row with the
  SAME event id (receivers dedup by webhook-id), keeps the attempt counter
  monotonic (attempt numbers stay unique in the history), and starts a
  fresh retry ladder through resend_baseline. Every resend records who
  asked. Both surfaces refuse anything but live endpoints. Replay filters
  rows, counts in a dry run, rate-limits the re-arms, and skips endpoints
  that are not live.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.ResendTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("resend_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.ResendTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("resend_test_deliveries")
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

  defmodule PlainDelivery do
    @moduledoc false
    # no resend_tracking declaration: the resend columns are NOT injected
    use Ash.Resource,
      domain: AshHooks.ResendTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("resend_plain_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Attempt do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.ResendTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundAttempt]

    sqlite do
      table("resend_test_attempts")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.ResendTest.Endpoint)
      resource(AshHooks.ResendTest.Delivery)
      resource(AshHooks.ResendTest.PlainDelivery)
      resource(AshHooks.ResendTest.Attempt)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Test.Repo

  @endpoints "resend_test_endpoints"
  @deliveries "resend_test_deliveries"
  @plain "resend_plain_deliveries"
  @attempts "resend_test_attempts"
  @payload Jason.encode!(%{"order" => 1})
  @secret "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    for table <- [@deliveries, @plain] do
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS #{table} (
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
        "CREATE UNIQUE INDEX IF NOT EXISTS #{table}_unique_delivery_index ON #{table} (endpoint_id, event_uuid)"
      )
    end

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@attempts} (
      id TEXT PRIMARY KEY, delivery_pk TEXT NOT NULL, endpoint_id TEXT NOT NULL,
      event_uuid TEXT NOT NULL, event_type TEXT NOT NULL, attempt INTEGER NOT NULL,
      outcome TEXT NOT NULL, reason TEXT, response_status INTEGER,
      response_snippet TEXT, response_headers TEXT, latency_ms INTEGER,
      signing_key_ref TEXT, test INTEGER NOT NULL DEFAULT 0,
      attempted_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@attempts}_unique_attempt_index ON #{@attempts} (delivery_pk, attempt)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@attempts}")
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@plain}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@attempts}")
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@plain}")
    Repo.query!("DELETE FROM #{@endpoints}")
    :ok
  end

  defp endpoint!(url \\ "https://hooks.example.test/accept") do
    Ash.create!(Endpoint, %{url: url, secret_ref: "resend-main"}, authorize?: false)
  end

  defp dead_row!(endpoint, event_uuid, opts \\ []) do
    Ash.create!(
      Delivery,
      %{
        event_uuid: event_uuid,
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: endpoint.id
      },
      action: :dispatch,
      authorize?: false
    )
    |> then(fn row ->
      Repo.query!(
        "UPDATE #{@deliveries} SET status = 'dead_letter', attempts = ?, last_error = 'http_500' WHERE id = ?",
        [opts[:attempts] || 3, row.id]
      )

      Ash.get!(Delivery, row.id, authorize?: false)
    end)
  end

  defp config(overrides) do
    Keyword.merge(
      [
        deliveries: Delivery,
        endpoints: Endpoint,
        attempts: Attempt,
        secret_resolver: fn "resend-main" -> {:ok, @secret} end
      ],
      overrides
    )
  end

  defp run_row(row, overrides) do
    DeliveryRuntime.run(
      %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid},
      Keyword.put(config(overrides), :ssrf_check, fn _url -> true end)
    )
  end

  test "a resend re-arms a terminal row with the same event id and records who asked" do
    endpoint = endpoint!()
    row = dead_row!(endpoint, "msg_resend_one", attempts: 3)

    assert {:ok, %{status: :resent}} =
             DeliveryRuntime.resend(row,
               requested_by: "ops-alice",
               endpoints: Endpoint,
               enqueue: fn _row, _event -> :ok end
             )

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.event_uuid == "msg_resend_one"
    assert final.status == :pending
    assert final.attempts == 3
    assert final.resend_baseline == 3
    assert final.resend_count == 1
    assert final.last_resend_by == "ops-alice"
    assert final.last_resend_at != nil
    assert final.last_error == nil
  end

  test "a resent row climbs a FRESH ladder: the baseline gates the ceiling" do
    endpoint = endpoint!()
    # dead-lettered AT the ceiling (attempts == ceiling)
    row = dead_row!(endpoint, "msg_resend_fresh", attempts: 3)

    assert {:ok, _} =
             DeliveryRuntime.resend(row,
               requested_by: "ops-alice",
               endpoints: Endpoint,
               enqueue: fn _, _ -> :ok end
             )

    # the ceiling stays 3 in this config: the fresh series dies at 3 more
    assert {:snooze, _} = run_row(row, max_attempts: 3)

    final = Ash.get!(Delivery, row.id, authorize?: false)
    assert final.attempts == 4
    assert final.status == :failed_retryable

    # and attempt history rows key uniquely across the boundary (attempt 4)
    assert [%{attempt: 4}] =
             Ash.read!(Attempt, authorize?: false)
             |> Enum.filter(&(&1.delivery_pk == %{"id" => row.id}))
  end

  test "a non-terminal row is not resendable (the named error)" do
    endpoint = endpoint!()

    row =
      Ash.create!(
        Delivery,
        %{
          event_uuid: "msg_resend_pending",
          event_type: "order_paid",
          payload: @payload,
          endpoint_id: endpoint.id
        },
        action: :dispatch,
        authorize?: false
      )

    assert {:error, :not_resendable} =
             DeliveryRuntime.resend(row, requested_by: "ops-alice", endpoints: Endpoint)
  end

  test "a resend against a not-live endpoint is refused" do
    endpoint = endpoint!()
    Repo.query!("UPDATE #{@endpoints} SET status = 'disabled' WHERE id = ?", [endpoint.id])
    row = dead_row!(endpoint, "msg_resend_disabled")

    assert {:error, :endpoint_not_live} =
             DeliveryRuntime.resend(row, requested_by: "ops-alice", endpoints: Endpoint)
  end

  test "a resend against a gone endpoint is refused" do
    endpoint = endpoint!()
    row = dead_row!(endpoint, "msg_resend_gone")
    Repo.query!("DELETE FROM #{@endpoints} WHERE id = ?", [endpoint.id])

    assert {:error, :endpoint_not_live} =
             DeliveryRuntime.resend(row, requested_by: "ops-alice", endpoints: Endpoint)
  end

  test "a resend requires requested_by and the tracking columns" do
    endpoint = endpoint!()
    row = dead_row!(endpoint, "msg_resend_who")

    assert {:error, :requested_by_required} = DeliveryRuntime.resend(row, requested_by: "")
    assert {:error, :requested_by_required} = DeliveryRuntime.resend(row)

    plain =
      Ash.create!(
        PlainDelivery,
        %{
          event_uuid: "msg_resend_plain",
          event_type: "order_paid",
          payload: @payload,
          endpoint_id: endpoint.id
        },
        action: :dispatch,
        authorize?: false
      )

    Repo.query!("UPDATE #{@plain} SET status = 'dead_letter' WHERE id = ?", [plain.id])

    assert {:error, %AshHooks.Errors.Unknown.UnknownError{error: error}} =
             DeliveryRuntime.resend(Ash.get!(PlainDelivery, plain.id, authorize?: false),
               requested_by: "ops-alice",
               endpoints: Endpoint
             )

    assert error =~ "resend_tracking"
  end

  test "a resend emits telemetry with ids and the requester" do
    test_pid = self()

    :telemetry.attach_many(
      "resend-test",
      [[:ash_hooks, :delivery, :resend]],
      fn event, _m, metadata, _c -> send(test_pid, {event, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach("resend-test") end)

    endpoint = endpoint!()
    row = dead_row!(endpoint, "msg_resend_telemetry")

    assert {:ok, _} =
             DeliveryRuntime.resend(row,
               requested_by: "ops-alice",
               endpoints: Endpoint,
               enqueue: fn _, _ -> :ok end
             )

    assert_receive {[:ash_hooks, :delivery, :resend],
                    %{
                      endpoint_id: _,
                      event_uuid: "msg_resend_telemetry",
                      requested_by: "ops-alice"
                    }}
  end

  describe "the enqueue seam and rearm fences" do
    defmodule Seam do
      @moduledoc false
      def ok(_row, _event), do: :ok
      def boom(_row, _event), do: {:error, :boom}
      def crash(_row, _event), do: raise("seam crashed")
      def invalid(_row, _event), do: :not_ok
      def throw_(_row, _event), do: throw(:seam_throw)
      def exit_(_row, _event), do: exit(:seam_exit)
    end

    test "a resend without an enqueue seam re-arms and defers driving" do
      endpoint = endpoint!()
      row = dead_row!(endpoint, "msg_resend_deferred")

      assert {:ok, %{status: :resent}} =
               DeliveryRuntime.resend(row, requested_by: "ops-alice", endpoints: Endpoint)

      assert Ash.get!(Delivery, row.id, authorize?: false).status == :pending
    end

    test "a failing enqueue seam is reported beside the re-arm, never fatal" do
      endpoint = endpoint!()

      for {seam, n} <-
            Enum.with_index([
              &Seam.boom/2,
              &Seam.crash/2,
              &Seam.invalid/2,
              &Seam.throw_/2,
              &Seam.exit_/2
            ]) do
        # a fresh terminal row per seam: each resend leaves the row pending
        row = dead_row!(endpoint, "msg_resend_seam_#{n}")

        assert {:ok, %{status: :resent, enqueue: {:error, _}}} =
                 DeliveryRuntime.resend(row,
                   requested_by: "ops-alice",
                   endpoints: Endpoint,
                   enqueue: seam
                 )
      end
    end

    test "an {m, f} enqueue seam applies" do
      endpoint = endpoint!()
      row = dead_row!(endpoint, "msg_resend_seam_mf")

      assert {:ok, %{status: :resent}} =
               DeliveryRuntime.resend(row,
                 requested_by: "ops-alice",
                 endpoints: Endpoint,
                 enqueue: {Seam, :ok}
               )
    end

    test "a resend whose gated write loses the race is the named error" do
      endpoint = endpoint!()
      row = dead_row!(endpoint, "msg_resend_race")

      # the gated update aborts: a concurrent writer moved the row first
      Repo.query!("""
      CREATE TRIGGER resend_abort
      BEFORE UPDATE ON #{@deliveries}
      WHEN NEW.status = 'pending' AND OLD.status = 'dead_letter'
      BEGIN
        SELECT RAISE(ABORT, 'forced resend rejection');
      END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS resend_abort") end)

      assert {:error, %Ash.Error.Unknown{}} =
               DeliveryRuntime.resend(row, requested_by: "ops-alice", endpoints: Endpoint)
    end

    test "a resend whose row moved under the gate is the named error" do
      endpoint = endpoint!()
      created = dead_row!(endpoint, "msg_resend_stale", attempts: 2)

      # the stored row is NOT terminal (a worker moved it); the in-memory
      # struct still claims dead_letter — the gated update matches nothing
      Repo.query!("UPDATE #{@deliveries} SET status = 'sending' WHERE id = ?", [created.id])

      # the in-memory struct still claims dead_letter — the gated update
      # matches nothing (the fence, not the stale read, decides)
      assert {:error, :not_resendable} =
               DeliveryRuntime.resend(created, requested_by: "ops-alice", endpoints: Endpoint)
    end

    test "a missing :endpoints module is a named error" do
      endpoint = endpoint!()
      row = dead_row!(endpoint, "msg_resend_no_endpoints")

      assert {:error, %AshHooks.Errors.Unknown.UnknownError{error: error}} =
               DeliveryRuntime.resend(row, requested_by: "ops-alice")

      assert error =~ ":endpoints"
    end

    test "a resent row terminalizes at the FRESH ceiling (baseline-aware exhaustion)" do
      endpoint = endpoint!()
      row = dead_row!(endpoint, "msg_resend_exhaust", attempts: 3)

      assert {:ok, _} =
               DeliveryRuntime.resend(row,
                 requested_by: "ops-alice",
                 endpoints: Endpoint,
                 enqueue: fn _, _ -> :ok end
               )

      # ceiling 1: the fresh series dies on its first failure
      assert :ok = run_row(row, max_attempts: 1)

      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :dead_letter
      assert final.attempts == 4
      assert final.last_error == "unresolved_host"
    end
  end

  describe "bulk replay" do
    test "a dry run counts the matching rows without touching them" do
      endpoint = endpoint!()
      dead_row!(endpoint, "msg_replay_1")
      dead_row!(endpoint, "msg_replay_2")

      other = endpoint!()
      row = dead_row!(other, "msg_replay_other")

      Repo.query!("UPDATE #{@deliveries} SET status = 'succeeded' WHERE id = ?", [row.id])

      assert {:ok, %{count: 2}} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 status: [:dead_letter],
                 endpoint_id: endpoint.id,
                 requested_by: "ops-alice",
                 endpoints: Endpoint,
                 dry_run: true
               )

      # untouched: both rows remain terminal after the dry run
      {:ok, %{records: dead_rows}} =
        AshHooks.Delivery.list(Delivery, endpoint_id: endpoint.id, status: [:dead_letter])

      assert length(dead_rows) == 2
      assert Enum.all?(dead_rows, &(&1.last_resend_by == nil))
    end

    test "replay re-arms matching rows, records who, and rate-limits" do
      endpoint = endpoint!()

      for i <- 1..3,
          do: dead_row!(endpoint, "msg_replay_live_#{i}")

      enqueued = Agent.start_link(fn -> 0 end)

      assert {:ok, %{resent: 3, skipped: 0}} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 status: [:dead_letter],
                 requested_by: "ops-alice",
                 endpoints: Endpoint,
                 enqueue: fn _row, _event -> :ok end,
                 per_second: 2,
                 limit: 10
               )

      rows = Ash.read!(Delivery, authorize?: false)
      assert Enum.all?(rows, &(&1.status == :pending))
      assert Enum.all?(rows, &(&1.last_resend_by == "ops-alice"))
      assert Enum.all?(rows, &(&1.resend_count == 1))

      {:ok, pid} = enqueued
      Agent.stop(pid)
    end

    test "replay skips rows whose endpoint is not live and reports them" do
      live = endpoint!()
      dead = endpoint!()
      Repo.query!("UPDATE #{@endpoints} SET status = 'disabled' WHERE id = ?", [dead.id])

      dead_row!(live, "msg_replay_live_ok")
      dead_row!(dead, "msg_replay_dead_ep")

      assert {:ok, %{resent: 1, skipped: 1}} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 status: [:dead_letter],
                 requested_by: "ops-alice",
                 endpoints: Endpoint,
                 enqueue: fn _, _ -> :ok end
               )
    end

    test "replay with no matching rows, no opts, and time bounds composes" do
      # the default-opts call fails on :requested_by (the \\ [] arm)
      assert {:error, :requested_by_required} = DeliveryRuntime.replay(Delivery)

      assert {:ok, %{resent: 0, skipped: 0}} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 requested_by: "ops-alice",
                 status: [:dead_letter],
                 from: DateTime.add(DateTime.utc_now(), 60, :second)
               )

      # a to-bound alone composes (the {nil, one} arm)
      assert {:ok, %{resent: 0, skipped: 0}} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 requested_by: "ops-alice",
                 status: [:dead_letter],
                 to: DateTime.add(DateTime.utc_now(), -60, :second)
               )

      endpoint = endpoint!()
      dead_row!(endpoint, "msg_replay_ranged")

      assert {:ok, %{count: 1}} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 requested_by: "ops-alice",
                 status: [:dead_letter],
                 from: DateTime.add(DateTime.utc_now(), -60, :second),
                 to: DateTime.add(DateTime.utc_now(), 60, :second),
                 dry_run: true
               )
    end

    test "replay counts a failed re-arm as skipped, never fatal" do
      endpoint = endpoint!()
      dead_row!(endpoint, "msg_replay_write_fail")

      Repo.query!("""
      CREATE TRIGGER replay_abort
      BEFORE UPDATE ON #{@deliveries}
      WHEN NEW.status = 'pending' AND OLD.status = 'dead_letter'
      BEGIN
        SELECT RAISE(ABORT, 'forced replay rejection');
      END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS replay_abort") end)

      assert {:ok, %{resent: 0, skipped: 1}} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 requested_by: "ops-alice",
                 status: [:dead_letter]
               )
    end

    test "a failed_retryable row at its FRESH ceiling terminalizes on re-drive" do
      endpoint = endpoint!()
      row = dead_row!(endpoint, "msg_resend_terminalize", attempts: 3)

      assert {:ok, _} =
               DeliveryRuntime.resend(row,
                 requested_by: "ops-alice",
                 endpoints: Endpoint,
                 enqueue: fn _, _ -> :ok end
               )

      # one attempt into the fresh series, then left retryable-and-due:
      # the next drive terminalizes through the baseline-aware gate
      Repo.query!(
        """
        UPDATE #{@deliveries}
        SET status = 'failed_retryable', attempts = 4, next_attempt_at = NULL
        WHERE id = ?
        """,
        [row.id]
      )

      assert :ok = run_row(row, max_attempts: 1)

      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :dead_letter
      assert final.last_error == "attempt_ceiling"
    end

    test "replay rejects an out-of-band limit and a missing status filter" do
      assert {:error, :invalid_limit} =
               DeliveryRuntime.replay(Delivery,
                 endpoints: Endpoint,
                 requested_by: "ops-alice",
                 status: [:dead_letter],
                 limit: 2_000
               )

      assert {:error, :status_filter_required} =
               DeliveryRuntime.replay(Delivery, endpoints: Endpoint, requested_by: "ops-alice")
    end

    test "replay requires the tracking columns and requested_by" do
      assert {:error, :requested_by_required} =
               DeliveryRuntime.replay(Delivery, endpoints: Endpoint, status: [:dead_letter])

      assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
               DeliveryRuntime.replay(PlainDelivery,
                 status: [:dead_letter],
                 requested_by: "x",
                 endpoints: Endpoint
               )
    end
  end
end
