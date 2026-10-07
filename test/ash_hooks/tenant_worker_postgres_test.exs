if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.TenantWorkerPostgresTest do
    @moduledoc """
    Opt-in qualification of the generated worker on a real PostgreSQL ledger,
    Oban.Basic, and Httpbun's public HTTPS informational-response endpoint.
    The persisted trigger is consumed in a fresh BEAM using the same checkout.
    """

    defmodule Tenant do
      @moduledoc false
      def parse(value), do: value |> to_string() |> String.upcase()
      def inverse(value), do: String.downcase(value)
    end

    defmodule Endpoint do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.TenantWorkerPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.Endpoint]

      postgres do
        table("tenant_worker_qualification_endpoints")
        repo(AshHooks.TestPostgres.Repo)
      end

      attributes do
        uuid_v7_primary_key(:id)
        attribute(:org_id, :string, allow_nil?: false)
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
        parse_attribute({AshHooks.TenantWorkerPostgresTest.Tenant, :parse, []})
        tenant_from_attribute({AshHooks.TenantWorkerPostgresTest.Tenant, :inverse, []})
      end

      actions do
        defaults([:read, :create, :update])
        default_accept(:*)
      end
    end

    defmodule Delivery do
      @moduledoc false
      use Ash.Resource,
        domain: AshHooks.TenantWorkerPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      postgres do
        table("tenant_worker_qualification_deliveries")
        repo(AshHooks.TestPostgres.Repo)
      end

      attributes do
        uuid_v7_primary_key(:id)
        attribute(:org_id, :string, allow_nil?: false)
        timestamps()
      end

      multitenancy do
        strategy(:attribute)
        attribute(:org_id)
        parse_attribute({AshHooks.TenantWorkerPostgresTest.Tenant, :parse, []})
        tenant_from_attribute({AshHooks.TenantWorkerPostgresTest.Tenant, :inverse, []})
      end

      actions do
        defaults([:read])
      end
    end

    defmodule Domain do
      @moduledoc false
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.TenantWorkerPostgresTest.Endpoint)
        resource(AshHooks.TenantWorkerPostgresTest.Delivery)
      end
    end

    defmodule Runtime do
      @moduledoc false
      alias AshHooks.TenantWorkerPostgresTest.Worker
      alias AshHooks.TestPostgres.Repo

      def secret(reference, tenant) do
        Application.fetch_env!(:ash_hooks, :tenant_worker_qualification_secrets)
        |> Map.fetch({reference, tenant})
      end

      def http_opts, do: [timeout: 10_000, max_body_bytes: 1_024]

      def oban_options do
        [
          engine: Oban.Engines.Basic,
          repo: Repo,
          prefix: "tenant_worker_qualification_oban",
          queues: false,
          plugins: [],
          name: AshHooks.TenantWorkerPostgresTest.Oban,
          testing: :disabled
        ]
      end

      def consume(repo_config, secrets, foreign_args) do
        Application.put_env(:ash_hooks, Repo, repo_config)
        Application.put_env(:ash_hooks, :tenant_worker_qualification_secrets, secrets)
        {:ok, _} = Application.ensure_all_started(:ash_hooks)
        {:ok, _} = Application.ensure_all_started(:ash_postgres)
        {:ok, _} = Application.ensure_all_started(:oban)
        {:ok, repo} = Repo.start_link()
        {:ok, oban} = Oban.start_link(oban_options())

        try do
          foreign_result = Worker.perform(%Oban.Job{args: foreign_args})

          foreign_rows =
            Repo.query!("""
            SELECT org_id, status, attempts
            FROM tenant_worker_qualification_deliveries
            ORDER BY org_id
            """).rows

          drained =
            Oban.drain_queue(AshHooks.TenantWorkerPostgresTest.Oban,
              queue: :tenant_worker_qualification,
              with_safety: false
            )

          %{
            foreign_result: foreign_result,
            foreign_rows: foreign_rows,
            drained: drained,
            os_pid: System.pid(),
            ash: to_string(Application.spec(:ash, :vsn)),
            ash_info_path: to_string(:code.which(Ash.Resource.Info))
          }
        after
          GenServer.stop(oban)
          Supervisor.stop(repo)
        end
      end
    end

    defmodule Worker do
      @moduledoc false
      alias AshHooks.TenantWorkerPostgresTest.Runtime

      use AshHooks.Worker,
        deliveries: AshHooks.TenantWorkerPostgresTest.Delivery,
        endpoints: AshHooks.TenantWorkerPostgresTest.Endpoint,
        secret_resolver: {Runtime, :secret},
        tenant_aware_secrets: true,
        http_opts: {Runtime, :http_opts, []},
        oban: AshHooks.TenantWorkerPostgresTest.Oban,
        queue: :tenant_worker_qualification
    end

    defmodule ObanMigration do
      @moduledoc false
      use Ecto.Migration
      def change, do: Oban.Migrations.up(prefix: "tenant_worker_qualification_oban")
    end

    use ExUnit.Case, async: false
    alias AshHooks.{Event, PrimaryKey}
    alias AshHooks.TestPostgres.Repo

    @moduletag :postgres
    @moduletag :httpbun
    @moduletag timeout: 120_000

    setup_all do
      Repo.query!("""
      CREATE TABLE tenant_worker_qualification_endpoints (
        id UUID PRIMARY KEY, org_id TEXT NOT NULL,
        url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
        secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
        legacy_previous_secret_ref TEXT
      )
      """)

      Repo.query!("""
      CREATE TABLE tenant_worker_qualification_deliveries (
        id UUID PRIMARY KEY, org_id TEXT NOT NULL,
        event_uuid TEXT NOT NULL, event_type TEXT NOT NULL, payload BYTEA NOT NULL,
        endpoint_id UUID NOT NULL, subscription_id UUID, signing_mode TEXT,
        status TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
        attempt_token UUID, send_lease_expires_at TIMESTAMP,
        enqueue_token UUID, enqueue_lease_expires_at TIMESTAMP, endpoint_snapshot JSONB,
        response_status INTEGER, response_snippet TEXT, last_error TEXT,
        next_attempt_at TIMESTAMP,
        dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
        dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
        inserted_at TIMESTAMP NOT NULL, updated_at TIMESTAMP NOT NULL
      )
      """)

      Repo.query!("""
      CREATE UNIQUE INDEX tenant_worker_qualification_identity
      ON tenant_worker_qualification_deliveries (org_id, endpoint_id, event_uuid)
      """)

      Repo.query!("CREATE SCHEMA tenant_worker_qualification_oban")

      :ok =
        Ecto.Migrator.up(Repo, 2_026_100_602, ObanMigration,
          prefix: "tenant_worker_qualification_oban",
          log: false
        )

      on_exit(fn ->
        Repo.query!("DROP TABLE tenant_worker_qualification_deliveries")
        Repo.query!("DROP TABLE tenant_worker_qualification_endpoints")
        Repo.query!("DROP SCHEMA tenant_worker_qualification_oban CASCADE")
      end)

      :ok
    end

    test "a parsed-tenant persisted job is consumed by a fresh BEAM over default HTTPS" do
      {:ok, event} =
        Event.new(
          type: :qualification,
          payload: Jason.encode!(%{at: DateTime.utc_now(), run: Ash.UUID.generate()})
        )

      # The attacker is seeded first. A foreign job cannot resolve the victim
      # ledger, even though both tenants carry the same event UUID.
      attacker_endpoint = endpoint!("AtTaCkEr", "attacker-key")
      attacker = delivery!(attacker_endpoint, event, "AtTaCkEr")
      victim_endpoint = endpoint!("ViCtIm", "victim-key")
      victim = delivery!(victim_endpoint, event, "ViCtIm")
      assert attacker.org_id == "ATTACKER"
      assert victim.org_id == "VICTIM"

      assert [attacker.id] ==
               Enum.map(Ash.read!(Delivery, tenant: "attacker", authorize?: false), & &1.id)

      {:ok, oban} = Oban.start_link(Runtime.oban_options())

      try do
        assert :ok = Worker.enqueue(victim, event)
      after
        GenServer.stop(oban)
      end

      assert [[job_id, "available", args]] =
               Repo.query!(
                 "SELECT id, state, args FROM tenant_worker_qualification_oban.oban_jobs"
               ).rows

      assert is_integer(job_id)
      assert args["tenant"] == "victim"
      assert args["delivery_pk"] == PrimaryKey.encode(victim)
      assert args["endpoint_id"] == victim_endpoint.id
      foreign_args = Map.put(args, "tenant", "attacker")

      {:ok, peer, _node} =
        :peer.start_link(%{
          connection: :standard_io,
          args: [~c"+S", ~c"2", ~c"-pa" | :code.get_path()],
          wait_boot: 30_000
        })

      result =
        try do
          :ok =
            :peer.call(peer, Application, :put_env, [
              :ash,
              :default_string_length_count,
              :codepoints
            ])

          {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:ex_unit])
          :ok = :peer.call(peer, ExUnit, :start, [[autorun: false]])
          :peer.call(peer, Mix, :start, [])
          :peer.call(peer, Code, :compile_file, [__ENV__.file], 30_000)

          secrets = %{
            {"attacker-key", "attacker"} => AshHooks.Signing.generate_secret(),
            {"victim-key", "victim"} => AshHooks.Signing.generate_secret()
          }

          :peer.call(peer, Runtime, :consume, [Repo.config(), secrets, foreign_args], 60_000)
        after
          :peer.stop(peer)
        end

      refute result.os_pid == System.pid()
      assert result.ash == to_string(Application.spec(:ash, :vsn))
      assert result.foreign_result == :ok
      assert result.foreign_rows == [["ATTACKER", "pending", 0], ["VICTIM", "pending", 0]]
      assert %{failure: 0, snoozed: 0, success: 1} = result.drained

      assert [[^job_id, "completed", 1]] =
               Repo.query!(
                 "SELECT id, state, attempt FROM tenant_worker_qualification_oban.oban_jobs"
               ).rows

      delivered = Ash.get!(Delivery, victim.id, tenant: "victim", authorize?: false)
      assert delivered.org_id == "VICTIM"
      assert delivered.status == :succeeded
      assert delivered.response_status == 200
      assert delivered.attempts == 1
      assert Ash.get!(Delivery, attacker.id, tenant: "attacker", authorize?: false).attempts == 0

      IO.puts(
        "TENANT WORKER OK: Ash #{result.ash}; parent #{System.pid()}; peer #{result.os_pid}; " <>
          "Basic job completed; tenant victim -> VICTIM; attacker-first foreign args made zero attempts; " <>
          "alias MFA HTTP options resolved; default Bounded POST https://httpbun.com/status/103 reached final 200; #{result.ash_info_path}"
      )
    end

    defp endpoint!(tenant, reference) do
      Ash.create!(Endpoint, %{url: "https://httpbun.com/status/103", secret_ref: reference},
        tenant: tenant,
        authorize?: false
      )
    end

    defp delivery!(endpoint, event, tenant) do
      Ash.create!(
        Delivery,
        %{
          event_uuid: event.id,
          event_type: "qualification",
          payload: event.payload,
          endpoint_id: endpoint.id
        },
        tenant: tenant,
        action: :dispatch,
        authorize?: false
      )
    end
  end
end
