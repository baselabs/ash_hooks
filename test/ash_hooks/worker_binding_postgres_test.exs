if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.WorkerBindingPostgresTest do
    use ExUnit.Case, async: false

    alias AshHooks.Event
    alias AshHooks.Test.HttpReceiver
    alias AshHooks.TestPostgres.Repo, as: OwnerRepo

    @moduletag :postgres
    @binding_key "ash_hooks_binding"
    @queue :dynamic_repo_webhooks

    defmodule Repo do
      use AshPostgres.Repo, otp_app: :ash_hooks, warn_on_missing_ash_functions?: false
      def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
    end

    defmodule VaultRepo do
      use Ecto.Repo, otp_app: :ash_hooks, adapter: Ecto.Adapters.Postgres
    end

    defmodule Custodian do
      @behaviour AshHooks.Custody
      alias AshHooks.Test.TableCustodian

      @store {VaultRepo, :postgres}

      def setup_store!, do: TableCustodian.setup_store!(@store)

      @impl true
      def store(ref, material, tenant, kind),
        do: TableCustodian.store(@store, ref, material, tenant, kind)

      @impl true
      def sign(ref, tenant, kind, input),
        do: TableCustodian.sign(@store, ref, tenant, kind, input)

      @impl true
      def verify(ref, tenant, kind, input, mac),
        do: TableCustodian.verify(@store, ref, tenant, kind, input, mac)

      @impl true
      def public_key(ref, tenant, kind), do: TableCustodian.public_key(@store, ref, tenant, kind)

      @impl true
      def fingerprint(ref, tenant, kind),
        do: TableCustodian.fingerprint(@store, ref, tenant, kind)

      @impl true
      def destroy(ref, tenant), do: TableCustodian.destroy(@store, ref, tenant)
    end

    defmodule Registry do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.KeyRegistry]

      postgres do
        table "binding_key_registry"
        repo(Repo)
      end
    end

    defmodule CustodyEndpoint do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.Endpoint]

      postgres do
        table "binding_custody_endpoints"
        repo(Repo)
      end

      actions do
        default_accept :*
        defaults [:read, :create, :update]
      end

      endpoint do
        key_lifecycle :on
        custodian Custodian
        key_registry Registry
      end
    end

    defmodule Endpoint do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.Endpoint]

      postgres do
        table "binding_endpoints"
        repo(Repo)
      end

      actions do
        default_accept :*
        defaults [:read, :create, :update]
      end
    end

    defmodule Delivery do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.OutboundDelivery]

      postgres do
        table "binding_deliveries"
        repo(Repo)
      end

      attributes do
        timestamps()
      end

      actions do
        defaults [:read]
      end
    end

    defmodule Attempt do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.OutboundAttempt]

      postgres do
        table "binding_attempts"
        repo(Repo)
      end

      actions do
        defaults [:read]
      end
    end

    defmodule Subscription do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.Subscription]

      postgres do
        table "binding_subscriptions"
        repo(Repo)
      end

      actions do
        default_accept :*
        defaults [:read, :create]
      end

      subscription do
        endpoint_resource Endpoint
      end
    end

    defmodule Emitter do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks]

      postgres do
        table "binding_emitters"
        repo(Repo)
      end

      actions do
        defaults [:read]
      end

      attributes do
        uuid_primary_key :id
      end

      webhooks do
        outbound :changed do
          subscriptions Subscription
          deliveries Delivery
        end
      end
    end

    defmodule Runtime do
      def secret("timeout"), do: Process.sleep(:infinity)
      def secret("crash"), do: Process.exit(self(), :kill)
      def secret("receiver"), do: {:ok, AshHooks.Signing.generate_secret()}

      def allow(_url, _context), do: :allow
    end

    defmodule Binding do
      @behaviour AshHooks.Binding

      @impl true
      def current do
        case VaultRepo.get_dynamic_repo() do
          VaultRepo -> "a"
          AshHooks.WorkerBindingPostgresTest.VaultRepoB -> "b"
          _unmapped -> nil
        end
      end

      @impl true
      def bind(name) when name in ["a", "b"] do
        Repo.put_dynamic_repo(repo_instance(name))
        VaultRepo.put_dynamic_repo(vault_instance(name))
        :ok
      end

      def bind("broken") do
        :ok = bind("b")
        raise "binding failed"
      end

      def bind(_unknown), do: {:error, :unknown_binding}

      @impl true
      def oban("a"), do: AshHooks.WorkerBindingPostgresTest.ObanA
      def oban("b"), do: AshHooks.WorkerBindingPostgresTest.ObanB

      def repo_instance("a"), do: Repo
      def repo_instance("b"), do: AshHooks.WorkerBindingPostgresTest.RepoB

      def vault_instance("a"), do: VaultRepo
      def vault_instance("b"), do: AshHooks.WorkerBindingPostgresTest.VaultRepoB
    end

    defmodule CustodyWorker do
      use AshHooks.Worker,
        deliveries: Delivery,
        endpoints: CustodyEndpoint,
        binding: Binding,
        destination_policy: {Runtime, :allow},
        http_opts: [validate_destination: false, timeout: 2_000],
        queue: :dynamic_repo_webhooks
    end

    defmodule UnboundWorker do
      use AshHooks.Worker,
        deliveries: Delivery,
        endpoints: Endpoint,
        secret_resolver: {Runtime, :secret},
        destination_policy: {Runtime, :allow},
        http_opts: [validate_destination: false, timeout: 2_000],
        oban: AshHooks.WorkerBindingPostgresTest.ObanA,
        queue: :dynamic_repo_webhooks
    end

    defmodule Worker do
      use AshHooks.Worker,
        deliveries: Delivery,
        endpoints: Endpoint,
        attempts: Attempt,
        outbox: AshHooks.WorkerBindingPostgresTest.Outbox,
        secret_resolver: {Runtime, :secret},
        destination_policy: {Runtime, :allow},
        http_opts: [validate_destination: false, timeout: 2_000],
        attempt_timeout: 5_000,
        finalization_allowance: 5_000,
        binding: Binding,
        queue: :dynamic_repo_webhooks
    end

    defmodule Outbox do
      use Ash.Resource,
        domain: AshHooks.WorkerBindingPostgresTest.Domain,
        data_layer: AshPostgres.DataLayer,
        extensions: [AshHooks.OutboundOutbox]

      postgres do
        table "binding_publications"
        repo(Repo)
      end

      actions do
        defaults [:read]
      end

      outbox do
        declarations [{Emitter, :changed}]
        delivery_routes default: {Worker, :enqueue}
        trigger {Worker, :enqueue_fanout}
        deduplication_horizon_seconds 3600
      end
    end

    defmodule Domain do
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource Attempt
        resource CustodyEndpoint
        resource Delivery
        resource Emitter
        resource Endpoint
        resource Outbox
        resource Registry
        resource Subscription
      end
    end

    defmodule ObanMigration do
      use Ecto.Migration
      def up, do: Oban.Migrations.up(prefix: prefix())
    end

    @resources [
      Attempt,
      CustodyEndpoint,
      Delivery,
      Emitter,
      Endpoint,
      Outbox,
      Registry,
      Subscription
    ]
    @query_events [
      [:ash_hooks_binding_test, :ledger, :query],
      [:ash_hooks_binding_test, :vault, :query]
    ]

    setup_all do
      for name <- ["a", "b"] do
        database = "ash_hooks_binding_" <> String.replace(Ecto.UUID.generate(), "-", "")
        OwnerRepo.query!("CREATE DATABASE " <> database)
        on_exit(fn -> OwnerRepo.query!("DROP DATABASE " <> database <> " WITH (FORCE)") end)

        instance = Binding.repo_instance(name)
        prefix = oban_prefix(name)

        options =
          Keyword.merge(OwnerRepo.config(),
            name: instance,
            database: database,
            telemetry_prefix: [:ash_hooks_binding_test, :ledger]
          )

        start_supervised!(Supervisor.child_spec({Repo, options}, id: instance))

        vault = Binding.vault_instance(name)

        vault_options =
          Keyword.merge(options, name: vault, telemetry_prefix: [:ash_hooks_binding_test, :vault])

        start_supervised!(Supervisor.child_spec({VaultRepo, vault_options}, id: vault))

        on_binding(name, fn ->
          create_tables()
          Custodian.setup_store!()
          Repo.query!("CREATE SCHEMA #{prefix}")

          :ok =
            Ecto.Migrator.up(Repo, 1, ObanMigration,
              dynamic_repo: instance,
              prefix: prefix,
              log: false
            )
        end)

        start_supervised!(
          {Oban,
           name: Binding.oban(name),
           repo: Repo,
           prefix: prefix,
           get_dynamic_repo: {Binding, :repo_instance, [name]},
           engine: Oban.Engines.Basic,
           testing: :manual}
        )
      end

      :ok
    end

    setup do
      for name <- ["a", "b"] do
        on_binding(name, fn ->
          tables = Enum.map_join(@resources, ", ", &AshPostgres.DataLayer.Info.table/1)

          Repo.query!(
            "TRUNCATE #{oban_prefix(name)}.oban_jobs, #{tables}, custody_conformance_keys"
          )
        end)
      end

      {server, port} = HttpReceiver.start()
      on_exit(fn -> :inets.stop(:httpd, server) end)
      %{port: port}
    end

    test "enqueue in B persists in B, and Oban delivers a row absent from A", %{port: port} do
      event = event("B only")

      row =
        on_binding("b", fn ->
          row = delivery!(endpoint!(port, 200), event)
          assert :ok = Worker.enqueue(row, event)
          assert :ok = Worker.enqueue(row, event)
          row
        end)

      assert jobs("a") == []
      assert [%Oban.Job{args: %{@binding_key => "b"}}] = jobs("b")
      assert %{success: 1, cancelled: 0} = drain("b")
      assert_receive {:http_received, %{body: "B only"}}
      assert read("a", Delivery) == []
      assert read("a", Attempt) == []
      assert [%{id: id, status: :succeeded, attempts: 1}] = read("b", Delivery)
      assert id == row.id
      assert [%{outcome: :succeeded, attempt: 1}] = read("b", Attempt)
    end

    test "the driver never reads the same delivery and endpoint IDs in A", %{port: port} do
      endpoint_a = endpoint!(port, 503)
      event_a = event("wrong database")
      delivery_a = delivery!(endpoint_a, event_a)
      assert :ok = Worker.enqueue(delivery_a, event_a)

      on_binding("b", fn ->
        endpoint_b = endpoint!(port, 200)

        Repo.query!("UPDATE binding_endpoints SET id = $1 WHERE id = $2", [
          Ecto.UUID.dump!(endpoint_a.id),
          Ecto.UUID.dump!(endpoint_b.id)
        ])

        event_b = %{event_a | payload: "right database"}
        delivery_b = delivery!(endpoint_a, event_b, id: delivery_a.id)
        assert :ok = Worker.enqueue(delivery_b, event_b)
      end)

      assert %{success: 1} = drain("b")
      assert_receive {:http_received, %{path: "/200", body: "right database"}}
      refute_receive {:http_received, _request}
      assert [%{status: :pending, attempts: 0}] = read("a", Delivery)
      assert read("a", Attempt) == []
      assert [%{status: :succeeded, attempts: 1}] = read("b", Delivery)
    end

    test "the driver signs with the custodian's key from the bound vault", %{port: port} do
      kind = {:standard_webhooks, :v1}
      event = event("signed by B")

      {endpoint, disclosure} =
        on_binding("b", fn ->
          {:ok, endpoint, disclosure} =
            AshHooks.Endpoint.create_with_key(
              CustodyEndpoint,
              %{url: "http://localhost:#{port}/200"},
              generate: kind
            )

          assert :ok = CustodyWorker.enqueue(delivery!(endpoint, event), event)
          {endpoint, disclosure}
        end)

      wrong_material = :crypto.strong_rand_bytes(32)
      assert :ok = Custodian.store(endpoint.secret_ref, wrong_material, nil, kind)

      assert %{success: 1} = drain("b")
      assert_receive {:http_received, %{body: "signed by B", headers: headers}}
      assert {:ok, _} = AshHooks.Signing.verify(event.payload, headers, disclosure)
    end

    for {ref, reason} <- [{"timeout", "attempt_timeout"}, {"crash", "driver_crash"}] do
      test "the #{ref} finalizer records the failed attempt in B", %{port: port} do
        secret_ref = unquote(ref)
        reason = unquote(reason)
        event = event(secret_ref)
        row_a = delivery!(endpoint!(port, 200), event)
        assert :ok = Worker.enqueue(row_a, event)

        on_binding("b", fn ->
          row_b = delivery!(endpoint!(port, 200, secret_ref), event, id: row_a.id)
          assert :ok = Worker.enqueue(row_b, event)
        end)

        assert %{snoozed: 1} = drain("b")

        assert [%{status: :failed_retryable, last_error: ^reason, attempts: 1}] =
                 read("b", Delivery)

        assert [%{outcome: :failed_retryable, reason: ^reason, attempt: 1}] = read("b", Attempt)
        assert [%{status: :pending, attempts: 0}] = read("a", Delivery)
        assert read("a", Attempt) == []
        refute_received {:http_received, _request}
      end
    end

    test "fanout routes by the vault repo, and retry and reconcile stay on that binding", %{
      port: port
    } do
      subscribe!(endpoint!(port, 200))
      event = event("from B")

      on_binding("b", fn ->
        subscribe!(endpoint!(port, 503))
        assert {:ok, :accepted} = AshHooks.publish(Outbox, {Emitter, :changed}, event)
      end)

      assert [%Oban.Job{args: %{"kind" => "fanout", @binding_key => "b"}}] = jobs("b")
      assert %{success: 1} = drain("b")
      assert [%{state: :done}] = read("b", Outbox)

      assert [%Oban.Job{id: id, args: %{"delivery_pk" => _, @binding_key => "b"}}] =
               jobs("b", "available")

      assert %{snoozed: 1} = drain("b")
      assert_receive {:http_received, %{path: "/503", body: "from B"}}
      assert [%Oban.Job{id: ^id, args: %{@binding_key => "b"}}] = jobs("b", "scheduled")
      assert [%{status: :failed_retryable, response_status: 503}] = read("b", Delivery)

      assert :ok = Oban.cancel_job(Binding.oban("b"), id)

      on_binding("b", fn ->
        Repo.query!(
          "UPDATE binding_deliveries SET next_attempt_at = CURRENT_TIMESTAMP - INTERVAL '1 second'"
        )

        assert {:ok, [%{status: :reconciled}]} =
                 AshHooks.reconcile_pending(Emitter, :changed, enqueue: {Worker, :enqueue})
      end)

      assert [%Oban.Job{id: recovered_id, args: %{"delivery_pk" => _, @binding_key => "b"}}] =
               jobs("b", "available")

      assert recovered_id != id
      assert jobs("a") == []
      assert read("a", Outbox) == []
      assert read("a", Delivery) == []
      assert read("a", Attempt) == []
    end

    test "the publication sweep stays on the caller's binding", %{port: port} do
      on_binding("b", fn ->
        subscribe!(endpoint!(port, 200))
        event = event("swept")

        assert {:ok, :accepted, [_ | _]} =
                 AshHooks.publish(Outbox, {Emitter, :changed}, event, return_notifications?: true)

        assert jobs("b") == []
        assert {:ok, %{done: 1, errors: []}} = AshHooks.fanout_pending(Outbox, 10)
      end)

      assert jobs("a") == []
      assert read("a", Outbox) == []
      assert [%Oban.Job{args: %{"delivery_pk" => _, @binding_key => "b"}}] = jobs("b")
      assert [%{state: :done}] = read("b", Outbox)
    end

    test "a legacy job uses the caller's repo after a bound job in the same process", %{
      port: port
    } do
      row_a = enqueue!(port, "legacy A")
      on_binding("b", fn -> enqueue!(port, "bound B") end)
      [job_a] = jobs("a")
      [job_b] = jobs("b")
      legacy_job = %{job_a | args: Map.delete(job_a.args, @binding_key)}

      assert :ok = Worker.perform(job_b)
      assert Repo.get_dynamic_repo() == Repo
      assert VaultRepo.get_dynamic_repo() == VaultRepo
      assert_receive {:http_received, %{body: "bound B"}}
      assert :ok = Worker.perform(legacy_job)
      assert_receive {:http_received, %{body: "legacy A"}}
      assert [%{id: id, status: :succeeded, attempts: 1}] = read("a", Delivery)
      assert id == row_a.id
    end

    test "an unknown binding cancels without reading the default delivery", %{port: port} do
      enqueue!(port, "should never be sent")
      [job] = jobs("a")
      args = Map.put(job.args, @binding_key, "unknown")

      assert {:ok, persisted} = Oban.insert(Binding.oban("a"), Worker.new(args))
      assert :ok = Oban.cancel_job(Binding.oban("a"), job.id)
      assert %{cancelled: 1, failure: 0} = drain("a")

      assert [%Oban.Job{id: id, state: "cancelled", errors: [%{"error" => error}]}] =
               Enum.filter(jobs("a"), &(&1.id == persisted.id))

      assert id == persisted.id
      assert error =~ "unknown_binding"

      assert {:cancel, :unknown_binding} =
               Worker.perform(%{job | args: Map.put(args, @binding_key, nil)})

      assert [%{status: :pending, attempts: 0}] = read("a", Delivery)
      assert read("a", Attempt) == []
      refute_received {:http_received, _request}
    end

    test "a keyed job is canceled before storage when its worker has no binding", %{port: port} do
      event = event("should never be sent")
      row = delivery!(endpoint!(port, 200), event)
      assert :ok = UnboundWorker.enqueue(row, event)
      [job] = jobs("a")
      args = Map.put(job.args, @binding_key, "b")

      observe_storage_queries()
      assert {:cancel, :unknown_binding} = UnboundWorker.perform(%{job | args: args})
      refute_received :storage_query
      refute_received {:http_received, _request}
    end

    test "a raising bind fails before storage and restores ledger and vault repos", %{port: port} do
      enqueue!(port, "should never be sent")
      [job] = jobs("a")
      args = Map.put(job.args, @binding_key, "broken")

      observe_storage_queries()
      assert {:error, :binding_failed} = Worker.perform(%{job | args: args})
      refute_received :storage_query
      assert Repo.get_dynamic_repo() == Repo
      assert VaultRepo.get_dynamic_repo() == VaultRepo
      refute_received {:http_received, _request}
    end

    test "enqueue refuses a process with no valid binding name", %{port: port} do
      event = event("invalid binding")
      row = delivery!(endpoint!(port, 200), event)
      previous = VaultRepo.put_dynamic_repo(:unmapped)

      try do
        assert {:error, :invalid_binding_name} = Worker.enqueue(row, event)
      after
        VaultRepo.put_dynamic_repo(previous)
      end

      assert jobs("a") == []
      assert jobs("b") == []
    end

    test "a worker refuses a binding module missing the callbacks" do
      definition =
        quote do
          defmodule AshHooks.WorkerBindingPostgresTest.InvalidWorker do
            use AshHooks.Worker, deliveries: Delivery, endpoints: Endpoint, binding: Repo
          end
        end

      assert_raise ArgumentError, ~r/:binding must implement AshHooks.Binding/, fn ->
        Code.compile_quoted(definition)
      end
    end

    defp on_binding(name, fun) do
      previous = Repo.get_dynamic_repo()
      previous_vault = VaultRepo.get_dynamic_repo()
      :ok = Binding.bind(name)

      try do
        fun.()
      after
        Repo.put_dynamic_repo(previous)
        VaultRepo.put_dynamic_repo(previous_vault)
      end
    end

    defp observe_storage_queries do
      id = make_ref()

      :ok =
        :telemetry.attach_many(
          id,
          @query_events,
          fn _name, _measurements, _metadata, caller -> send(caller, :storage_query) end,
          self()
        )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp read(name, resource),
      do: on_binding(name, fn -> Ash.read!(resource, authorize?: false) end)

    defp oban_prefix(name), do: "binding_jobs_#{name}"

    defp jobs(name), do: on_binding(name, fn -> Repo.all(Oban.Job, prefix: oban_prefix(name)) end)
    defp jobs(name, state), do: Enum.filter(jobs(name), &(&1.state == state))

    defp drain(name) do
      Oban.drain_queue(Binding.oban(name), queue: @queue, with_safety: false)
    end

    defp endpoint!(port, status, secret_ref \\ "receiver") do
      Ash.create!(
        Endpoint,
        %{url: "http://localhost:#{port}/#{status}", secret_ref: secret_ref},
        authorize?: false
      )
    end

    defp subscribe!(endpoint) do
      Ash.create!(
        Subscription,
        %{endpoint_id: endpoint.id, event_types: ["changed"]},
        authorize?: false
      )
    end

    defp enqueue!(port, payload) do
      event = event(payload)
      delivery = delivery!(endpoint!(port, 200), event)
      assert :ok = Worker.enqueue(delivery, event)
      delivery
    end

    defp delivery!(endpoint, event, opts \\ []) do
      input = %{
        event_uuid: event.id,
        event_type: event.type,
        payload: event.payload,
        endpoint_id: endpoint.id
      }

      Ash.create!(Delivery, Map.merge(input, Map.new(opts)), action: :dispatch, authorize?: false)
    end

    defp event(payload) do
      {:ok, event} = Event.new(type: :changed, payload: payload)
      event
    end

    defp create_tables do
      for resource <- @resources do
        table = AshPostgres.DataLayer.Info.table(resource)
        columns = Enum.map_join(Ash.Resource.Info.attributes(resource), ", ", &column/1)
        Repo.query!("CREATE TABLE #{table} (#{columns})")
      end

      for {table, columns} <- [
            {"binding_deliveries", "endpoint_id, event_uuid"},
            {"binding_attempts", "delivery_pk, attempt"},
            {"binding_publications", "event_uuid"}
          ] do
        Repo.query!("CREATE UNIQUE INDEX #{table}_identity ON #{table} (#{columns})")
      end
    end

    defp column(attribute) do
      storage = Ash.Type.storage_type(attribute.type, attribute.constraints)
      type = column_type(attribute.name, storage)
      "\"#{attribute.name}\" #{type}" <> if(attribute.primary_key?, do: " PRIMARY KEY", else: "")
    end

    defp column_type(:metadata, :map), do: "JSON"
    defp column_type(_name, :uuid), do: "UUID"
    defp column_type(_name, :binary), do: "BYTEA"
    defp column_type(_name, :map), do: "JSONB"
    defp column_type(_name, {:array, _}), do: "TEXT[]"
    defp column_type(_name, :boolean), do: "BOOLEAN"
    defp column_type(_name, type) when type in [:integer, :bigint], do: "BIGINT"

    defp column_type(_name, type) when type in [:utc_datetime_usec, :utc_datetime],
      do: "TIMESTAMP(6)"

    defp column_type(_name, _type), do: "TEXT"
  end
end
