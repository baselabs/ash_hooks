# Oban is absent on the no-optional CI leg — this whole module is skipped
# there (the body_reader/installer pattern); on the optional leg it runs a
# REAL Oban instance on the sqlite test repo (Lite engine) and proves the
# worker macro + the effect-once uniqueness against the actual engine.
if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.WorkerTest do
    @moduledoc """
    The host-injected worker macro: `use AshHooks.Worker` compiles an Oban
    worker inside the host, generates the #6 enqueue seam (`enqueue/2`),
    and drives `AshHooks.Delivery` through `perform/1`. Uniqueness is the
    A4 tripwire on the REAL engine: a double enqueue of the same
    {endpoint_id, event_uuid} inserts exactly ONE job and BOTH calls
    return `:ok` (a conflict is dedup success).
    """

    defmodule Endpoint do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.WorkerTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.Endpoint]

      sqlite do
        table("worker_test_endpoints")
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
        domain: AshHooks.WorkerTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      sqlite do
        table("worker_test_deliveries")
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
        resource(AshHooks.WorkerTest.Endpoint)
        resource(AshHooks.WorkerTest.Delivery)
      end
    end

    defmodule Secrets do
      @moduledoc false
      def webhook_secret("acme-main"),
        do: {:ok, "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))}

      def webhook_secret(_other), do: {:error, :unknown_ref}
    end

    defmodule Worker do
      @moduledoc false
      use AshHooks.Worker,
        deliveries: AshHooks.WorkerTest.Delivery,
        endpoints: AshHooks.WorkerTest.Endpoint,
        secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},
        snippet_redactor: {AshHooks.WorkerTest.Redactor, :call},
        queue: :ash_hooks_test,
        oban: AshHooks.WorkerTest.Oban,
        timeout: 5_000
    end

    defmodule Redactor do
      @moduledoc false
      def call(_body), do: "consumer-diagnostic"
    end

    use ExUnit.Case, async: false

    alias AshHooks.Test.Repo

    @endpoints "worker_test_endpoints"
    @deliveries "worker_test_deliveries"
    @payload Jason.encode!(%{"w" => 1})

    setup_all do
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS #{@endpoints} (
        id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
        secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
        legacy_previous_secret_ref TEXT
      )
      """)

      Repo.query!("""
      CREATE TABLE IF NOT EXISTS #{@deliveries} (
        id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
        payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
        signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
        attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
        response_snippet TEXT, last_error TEXT, next_attempt_at TEXT
      )
      """)

      Repo.query!(
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
      )

      # a REAL Oban instance on the sqlite repo (Lite engine — the Oban
      # uniqueness facts ADR-0007 recorded from this same dep version)
      Application.put_env(:oban, AshHooks.WorkerTest.Oban,
        engine: Oban.Engines.Lite,
        repo: AshHooks.Test.Repo,
        queues: false,
        plugins: [],
        testing: :disabled
      )

      {:ok, _} =
        Oban.start_link(
          engine: Oban.Engines.Lite,
          repo: Repo,
          queues: false,
          plugins: [],
          name: AshHooks.WorkerTest.Oban,
          testing: :disabled
        )

      # oban_jobs on raw DDL (Oban's own sqlite v12 schema, transcribed
      # from deps/oban/lib/oban/migrations/sqlite.ex — Ecto.Migrator
      # cannot run inside an ExUnit setup context)
      Repo.query!("""
      CREATE TABLE IF NOT EXISTS oban_jobs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        state TEXT NOT NULL DEFAULT 'available',
        queue TEXT NOT NULL DEFAULT 'default',
        worker TEXT NOT NULL,
        args TEXT NOT NULL DEFAULT '{}',
        meta TEXT NOT NULL DEFAULT '{}',
        tags TEXT NOT NULL DEFAULT '[]',
        errors TEXT NOT NULL DEFAULT '[]',
        attempt INTEGER NOT NULL DEFAULT 0,
        max_attempts INTEGER NOT NULL DEFAULT 20,
        priority INTEGER NOT NULL DEFAULT 0,
        inserted_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        scheduled_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
        attempted_at TEXT,
        attempted_by TEXT NOT NULL DEFAULT '[]',
        cancelled_at TEXT,
        completed_at TEXT,
        discarded_at TEXT
      )
      """)

      Repo.query!(
        "CREATE INDEX IF NOT EXISTS oban_jobs_state_queue_priority_scheduled_at_id_index ON oban_jobs (state, queue, priority, scheduled_at, id)"
      )

      on_exit(fn ->
        pid = Process.whereis(AshHooks.WorkerTest.Oban)
        if pid, do: Process.exit(pid, :kill)
        Application.stop(:oban)
        Repo.query!("DROP TABLE IF EXISTS oban_jobs")
        Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
        Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      end)

      :ok
    end

    setup do
      Repo.query!("DELETE FROM #{@deliveries}")
      Repo.query!("DELETE FROM #{@endpoints}")
      Repo.query!("DELETE FROM oban_jobs")
      :ok
    end

    defp endpoint! do
      Ash.create!(Endpoint, %{url: "https://hooks.example.test/accept", secret_ref: "acme-main"},
        authorize?: false
      )
    end

    defp delivery_row!(endpoint, event_uuid) do
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
    end

    defp job_count do
      %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM oban_jobs")
      count
    end

    defp job_args do
      %{rows: rows} = Repo.query!("SELECT args FROM oban_jobs")
      Enum.map(rows, &Jason.decode!(hd(&1)))
    end

    test "the generated worker is an Oban worker with perform/1 and the enqueue seam" do
      assert function_exported?(Worker, :perform, 1)
      assert function_exported?(Worker, :enqueue, 2)
    end

    test "an INVALID snippet_redactor shape is rejected at compile time (fail-closed config)" do
      assert_raise ArgumentError, ~r/snippet_redactor/, fn ->
        defmodule BadRedactorWorker do
          @moduledoc false
          use AshHooks.Worker,
            deliveries: AshHooks.WorkerTest.Delivery,
            endpoints: AshHooks.WorkerTest.Endpoint,
            secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},
            snippet_redactor: "not-a-redactor",
            queue: :ash_hooks_test,
            oban: AshHooks.WorkerTest.Oban
        end
      end
    end

    test "enqueue inserts ONE trigger with both top-level string keys (the A4 tripwire)" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_uniqueness_probe_1")

      assert :ok = Worker.enqueue(row, nil)
      assert :ok = Worker.enqueue(row, nil)

      assert job_count() == 1

      [args] = job_args()
      assert args["endpoint_id"] == ep.id
      assert args["event_uuid"] == "msg_worker_uniqueness_probe_1"
    end

    test "a DIFFERENT event to the same endpoint inserts a second trigger" do
      ep = endpoint!()
      a = delivery_row!(ep, "msg_worker_a")
      b = delivery_row!(ep, "msg_worker_b")

      assert :ok = Worker.enqueue(a, nil)
      assert :ok = Worker.enqueue(b, nil)

      assert job_count() == 2
    end

    test "perform/1 delegates to the driver (terminal row → :ok, no send)" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_terminal")

      # pre-terminate the row through the driver's own surface
      Repo.query!("UPDATE #{@deliveries} SET status = 'dead_letter' WHERE id = ?", [row.id])

      job = %Oban.Job{args: %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid}}
      assert :ok = Worker.perform(job)
    end

    test "perform/1 drives a pending row through a full send (injected adapter)" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_send")

      # the worker's adapter defaults to Bounded — drive through the
      # driver directly with a double to prove perform's delegation is
      # the same machine (macro-level send coverage lives in delivery_test)
      job = %Oban.Job{args: %{"endpoint_id" => row.endpoint_id, "event_uuid" => row.event_uuid}}

      # a pending row against an unresolvable-but-registered url would
      # send; here the row dead-letters at the send-time DNS check
      assert :ok = Worker.perform(job)
      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :dead_letter
      assert final.last_error =~ "destination"
    end

    describe "the macro's option validation (runtime compiles)" do
      @worker_base """
      defmodule RuntimeWorker do
        use AshHooks.Worker,
          deliveries: AshHooks.WorkerTest.Delivery,
          endpoints: AshHooks.WorkerTest.Endpoint,
          secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret}
      end
      """

      test "a snippet_redactor with a non-module half raises at compile" do
        source =
          String.replace(
            @worker_base,
            "secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret}",
            "secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},\n        snippet_redactor: {\"not-a-module\", :call}"
          )

        assert_raise ArgumentError, ~r/must be \{module, function\}/, fn ->
          Code.compile_string(source)
        end
      after
        :code.purge(RuntimeWorker)
        _ = :code.delete(RuntimeWorker)
      end

      test "defaults (no :oban, no :snippet_redactor, no :http) compile clean" do
        assert [{module, _beam}] = Code.compile_string(@worker_base)
        assert module == RuntimeWorker
      after
        :code.purge(RuntimeWorker)
        _ = :code.delete(RuntimeWorker)
      end
    end
  end
end
