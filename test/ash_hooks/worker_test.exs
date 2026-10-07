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

    defmodule FailingReadPrep do
      @moduledoc false
      use Ash.Resource.Preparation

      alias Ash.Error.Query.InvalidQuery

      @impl true
      def prepare(query, _ctx, _opts) do
        Ash.Query.add_error(
          query,
          InvalidQuery.exception(message: "forced worker reload failure")
        )
      end
    end

    defmodule UnreadableDelivery do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.WorkerTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      sqlite do
        table("worker_test_deliveries")
        repo(AshHooks.Test.Repo)
      end

      preparations do
        prepare({AshHooks.WorkerTest.FailingReadPrep, []})
      end

      actions do
        defaults([:read])
      end
    end

    defmodule TenancyDelivery do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.WorkerTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      sqlite do
        table("tenancy_worker_deliveries")
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
        defaults([:read])
      end
    end

    # attribute value = String.upcase(tenant); the INVERSE strips back to
    # the tenant — exercises the enqueue's tenant_from_attribute inversion
    defmodule ParsedTenancyDelivery do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.WorkerTest.Domain,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      sqlite do
        table("tenancy_worker_deliveries")
        repo(AshHooks.Test.Repo)
      end

      attributes do
        attribute(:org_id, :string, allow_nil?: false)
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
        parse_attribute({__MODULE__, :upcase, []})
        tenant_from_attribute({__MODULE__, :downcase, []})
      end

      actions do
        defaults([:read])
      end

      def upcase(tenant), do: String.upcase(to_string(tenant))
      def downcase(attr), do: String.downcase(attr)
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.WorkerTest.Endpoint)
        resource(AshHooks.WorkerTest.Delivery)
        resource(AshHooks.WorkerTest.UnreadableDelivery)
        resource(AshHooks.WorkerTest.TenancyDelivery)
        resource(AshHooks.WorkerTest.ParsedTenancyDelivery)
      end
    end

    defmodule Secrets do
      @moduledoc false
      def webhook_secret("acme-main"),
        do: {:ok, "whsec_" <> Base.encode64(:crypto.strong_rand_bytes(32))}

      def webhook_secret(_other), do: {:error, :unknown_ref}
    end

    defmodule HttpOptions do
      @moduledoc false

      def slow do
        Process.sleep(500)
        [timeout: 5_000]
      end

      def crash, do: raise("http options failed")
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
        timeout: 35_000
    end

    defmodule SlowOptionsWorker do
      @moduledoc false
      use AshHooks.Worker,
        deliveries: AshHooks.WorkerTest.Delivery,
        endpoints: AshHooks.WorkerTest.Endpoint,
        secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},
        http_opts: {AshHooks.WorkerTest.HttpOptions, :slow, []},
        queue: :ash_hooks_test,
        oban: AshHooks.WorkerTest.Oban,
        timeout: 200,
        attempt_timeout: 50,
        finalization_allowance: 50
    end

    defmodule CrashingOptionsWorker do
      @moduledoc false
      use AshHooks.Worker,
        deliveries: AshHooks.WorkerTest.Delivery,
        endpoints: AshHooks.WorkerTest.Endpoint,
        secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},
        http_opts: {AshHooks.WorkerTest.HttpOptions, :crash, []},
        queue: :ash_hooks_test,
        oban: AshHooks.WorkerTest.Oban,
        timeout: 200,
        attempt_timeout: 50,
        finalization_allowance: 50
    end

    def http_opts, do: [timeout: 5_000]

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
        response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
        dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
        dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
        attempt_token TEXT, send_lease_expires_at TEXT,
        enqueue_token TEXT, enqueue_lease_expires_at TEXT,
        endpoint_snapshot TEXT
      )
      """)

      Repo.query!(
        "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
      )

      Repo.query!("""
      CREATE TABLE IF NOT EXISTS tenancy_worker_deliveries (
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
        org_id TEXT NOT NULL
      )
      """)

      Repo.query!(
        "CREATE UNIQUE INDEX IF NOT EXISTS tenancy_worker_deliveries_unique_delivery_index ON tenancy_worker_deliveries (org_id, endpoint_id, event_uuid)"
      )

      # a REAL Oban instance on the sqlite repo (Lite engine — the Oban
      # uniqueness facts ADR-0007 recorded from this same dep version)
      start_supervised!(
        {Oban,
         engine: Oban.Engines.Lite,
         repo: Repo,
         queues: false,
         plugins: [],
         name: AshHooks.WorkerTest.Oban,
         testing: :disabled}
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
        assert is_pid(Process.whereis(Oban.Registry)),
               "fixture teardown must preserve the shared Oban registry"

        Repo.query!("DROP TABLE IF EXISTS oban_jobs")
        Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
        Repo.query!("DROP TABLE IF EXISTS tenancy_worker_deliveries")
        Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      end)

      :ok
    end

    setup do
      Repo.query!("DELETE FROM #{@deliveries}")
      Repo.query!("DELETE FROM tenancy_worker_deliveries")
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
      assert args["delivery_pk"] == %{"id" => row.id}
      assert args["delivery_resource"] == Atom.to_string(Delivery)
      assert args["endpoint_resource"] == Atom.to_string(Endpoint)
      assert args["dispatch_source"] == row.dispatch_source
      assert is_binary(args["dispatch_route"])
    end

    test "route binding is idempotent and rejects a different persisted route" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_route_binding")
      route = AshHooks.OutboundBinding.named_route(Worker, :enqueue)
      other_route = AshHooks.OutboundBinding.named_route(SlowOptionsWorker, :enqueue)

      assert {:ok, bound} = AshHooks.Worker.bind_route(row, route, nil)
      assert {:ok, ^bound} = AshHooks.Worker.bind_route(bound, route, nil)

      assert {:error, :dispatch_route_conflict} =
               AshHooks.Worker.bind_route(bound, other_route, nil)

      assert {:error, :dispatch_route_conflict} =
               AshHooks.Worker.bind_route(row, other_route, nil)
    end

    test "route binding surfaces a real storage rejection" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_route_storage_error")
      route = AshHooks.OutboundBinding.named_route(Worker, :enqueue)

      Repo.query!("""
      CREATE TRIGGER worker_route_abort
      BEFORE UPDATE OF dispatch_route ON #{@deliveries}
      BEGIN
        SELECT RAISE(ABORT, 'forced route storage rejection');
      END
      """)

      on_exit(fn -> Repo.query!("DROP TRIGGER IF EXISTS worker_route_abort") end)

      assert {:error, %Ash.Error.Unknown{}} = AshHooks.Worker.bind_route(row, route, nil)
    end

    test "route binding surfaces a real Ash read failure after a lost CAS" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_route_read_error")
      route = AshHooks.OutboundBinding.named_route(Worker, :enqueue)
      other_route = AshHooks.OutboundBinding.named_route(SlowOptionsWorker, :enqueue)

      assert {:ok, _bound} = AshHooks.Worker.bind_route(row, route, nil)

      unreadable = struct(UnreadableDelivery, Map.from_struct(row))

      assert {:error, %Ash.Error.Invalid{}} =
               AshHooks.Worker.bind_route(unreadable, other_route, nil)
    end

    test "a canceled trigger does not suppress a fresh runnable trigger" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_cancel_recovery")

      assert :ok = Worker.enqueue(row, nil)
      %{rows: [[job_id]]} = Repo.query!("SELECT id FROM oban_jobs")
      assert :ok = Oban.cancel_job(AshHooks.WorkerTest.Oban, job_id)

      assert %{rows: [["cancelled"]]} =
               Repo.query!("SELECT state FROM oban_jobs WHERE id = ?", [job_id])

      assert :ok = Worker.enqueue(row, nil)
      assert job_count() == 2
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

      assert :ok = Worker.enqueue(row, nil)
      [args] = job_args()
      job = %Oban.Job{args: args}
      assert :ok = Worker.perform(job)
    end

    test "perform resolves a slow http_opts MFA inside the driver deadline" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_slow_http_opts")

      assert :ok = SlowOptionsWorker.enqueue(row, nil)
      [args] = job_args()
      started = System.monotonic_time(:millisecond)

      assert {:error, :attempt_timeout} = SlowOptionsWorker.perform(%Oban.Job{args: args})
      assert System.monotonic_time(:millisecond) - started < 250
      assert Ash.get!(Delivery, row.id, authorize?: false).status == :pending
    end

    test "perform contains a crashing http_opts MFA before ledger ownership" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_crashing_http_opts")

      assert :ok = CrashingOptionsWorker.enqueue(row, nil)
      [args] = job_args()

      assert {:error, {:driver_crash, "unclassified"}} =
               CrashingOptionsWorker.perform(%Oban.Job{args: args})

      assert Ash.get!(Delivery, row.id, authorize?: false).status == :pending
    end

    test "perform/1 drives a pending row through a full send (injected adapter)" do
      ep = endpoint!()
      row = delivery_row!(ep, "msg_worker_send")

      # the worker's adapter defaults to Bounded — drive through the
      # driver directly with a double to prove perform's delegation is
      # the same machine (macro-level send coverage lives in delivery_test)
      assert :ok = Worker.enqueue(row, nil)
      [args] = job_args()
      job = %Oban.Job{args: args}

      # a pending row against an unresolvable-but-registered url would
      # send; here the row dead-letters at the send-time DNS check
      assert :ok = Worker.perform(job)
      final = Ash.get!(Delivery, row.id, authorize?: false)
      assert final.status == :dead_letter
      assert final.last_error =~ "destination"
    end

    defp offset(source, needle) do
      case :binary.match(source, needle) do
        {idx, _len} -> idx
        :nomatch -> nil
      end
    end

    describe "the adapter-opts seam bake (cross-vendor review regression)" do
      test "the macro threads :http_opts into the baked delivery config" do
        path = Path.expand("../../lib/ash_hooks/worker.ex", __DIR__)
        source = File.read!(path)

        calculation_at = offset(source, "http_opts =")
        bake_at = offset(source, "http_opts: http_opts")
        config_at = offset(source, "delivery_config =")

        assert calculation_at && config_at && bake_at &&
                 calculation_at < config_at && bake_at > config_at,
               "use AshHooks.Worker must normalize :http_opts before baking it into delivery_config"
      end
    end

    describe "tenancy: the enqueue seam serializes the row tenant (D5)" do
      defmodule TenantWorker do
        @moduledoc false
        use AshHooks.Worker,
          deliveries: AshHooks.WorkerTest.TenancyDelivery,
          endpoints: AshHooks.WorkerTest.Endpoint,
          secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},
          queue: :ash_hooks_tenancy,
          oban: AshHooks.WorkerTest.Oban
      end

      defp tenancy_row!(endpoint, event_uuid, org) do
        Ash.create!(
          TenancyDelivery,
          %{
            event_uuid: event_uuid,
            event_type: "order_paid",
            payload: @payload,
            endpoint_id: endpoint.id
          },
          action: :dispatch,
          tenant: org,
          authorize?: false
        )
      end

      test "a multitenant row's enqueue carries the tenant arg; a single-tenant row's carries none" do
        endpoint = endpoint!()
        row = tenancy_row!(endpoint, "evt_tenancy_worker_1", "org_a")

        assert :ok = TenantWorker.enqueue(row, nil)

        [args] = job_args()
        assert args["endpoint_id"] == endpoint.id
        assert args["event_uuid"] == "evt_tenancy_worker_1"
        assert args["tenant"] == "org_a"

        # the single-tenant worker's row serializes NO tenant key (the
        # multitenancy attribute is undeclared there)
        plain = delivery_row!(endpoint, "evt_tenancy_worker_2")
        assert :ok = AshHooks.WorkerTest.Worker.enqueue(plain, nil)

        [tenant_args, plain_args] = Enum.sort_by(job_args(), &(not Map.has_key?(&1, "tenant")))
        assert tenant_args["tenant"] == "org_a"
        refute Map.has_key?(plain_args, "tenant")
      end

      test "a non-identity parse_attribute round-trips: the enqueue inverts through tenant_from_attribute, run parses back to the row" do
        defmodule ParsedTenantWorker do
          @moduledoc false
          use AshHooks.Worker,
            deliveries: AshHooks.WorkerTest.ParsedTenancyDelivery,
            endpoints: AshHooks.WorkerTest.Endpoint,
            secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},
            queue: :ash_hooks_tenancy,
            oban: AshHooks.WorkerTest.Oban
        end

        endpoint = endpoint!()

        row =
          Ash.create!(
            ParsedTenancyDelivery,
            %{
              event_uuid: "evt_parsed_roundtrip",
              event_type: "order_paid",
              payload: @payload,
              endpoint_id: endpoint.id
            },
            action: :dispatch,
            tenant: "MiXeD",
            authorize?: false
          )

        # the row stores the PARSED attribute; the args carry the TENANT
        assert row.org_id == "MIXED"

        assert :ok = ParsedTenantWorker.enqueue(row, nil)

        [args] = job_args()
        assert args["tenant"] == "mixed"

        # and the forward direction holds: the args tenant re-resolves the
        # row (parse_attribute("mixed") == "MIXED" == the stored attribute)
        found =
          Ash.get!(ParsedTenancyDelivery, row.id, tenant: args["tenant"], authorize?: false)

        assert found.id == row.id
      end

      test "full identity admits a tenant-bound job beside a legacy tenant-less trigger" do
        endpoint = endpoint!()

        # a pre-tenancy enqueued job: the 1.1.x args shape, same pair
        {:ok, _old_job} =
          Oban.insert(
            AshHooks.WorkerTest.Oban,
            Oban.Job.new(
              %{
                "endpoint_id" => endpoint.id,
                "event_uuid" => "evt_tenancy_cutover"
              },
              worker: TenantWorker,
              queue: :ash_hooks_tenancy
            )
          )

        assert job_count() == 1

        # The durable identity now includes the complete PK, source, route,
        # and tenant, so the old partial trigger cannot suppress admission.
        row = tenancy_row!(endpoint, "evt_tenancy_cutover", "org_a")

        assert :ok = TenantWorker.enqueue(row, nil)
        assert job_count() == 2
      end
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

      test "an {m, f, a} http_opts compiles (the runtime resolution path for computed bundles)" do
        source =
          String.replace(
            @worker_base,
            "secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret}",
            "secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},\n        http_opts: {AshHooks.WorkerTest, :http_opts, []}"
          )

        assert Enum.any?(Code.compile_string(source), fn {m, _} -> m == RuntimeWorker end)
      after
        _ = :code.purge(RuntimeWorker)
        _ = :code.delete(RuntimeWorker)
      end

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

      test "the Oban timeout must exceed the complete delivery deadline" do
        source =
          String.replace(
            @worker_base,
            "secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret}",
            "secret_resolver: {AshHooks.WorkerTest.Secrets, :webhook_secret},\n        timeout: 100,\n        attempt_timeout: 50,\n        finalization_allowance: 50"
          )

        assert_raise ArgumentError,
                     ~r/:timeout must exceed :attempt_timeout plus :finalization_allowance/,
                     fn -> Code.compile_string(source) end
      after
        _ = :code.purge(RuntimeWorker)
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
