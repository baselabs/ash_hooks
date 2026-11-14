defmodule AshHooks.Test.RowSecurityProvider do
  @moduledoc false
  use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]
  defstruct [:type, :payload]
  @impl true
  def handle_event(type, payload), do: {:ok, %__MODULE__{type: type, payload: payload}}
  @impl true
  def event_identity(payload),
    do: {:ok, Base.encode16(:crypto.hash(:sha256, Jason.encode!(payload)))}
end

defmodule AshHooks.Test.RowSecurityTracer do
  @moduledoc false
  @behaviour Ash.Tracer
  @impl true
  def get_span_context, do: Process.get(__MODULE__)
  @impl true
  def set_span_context(context) do
    Process.put(__MODULE__, context)
    :ok
  end

  @impl true
  def start_span(type, name) do
    :telemetry.execute([:row_security, :span], %{}, %{
      pid: self(),
      context: get_span_context(),
      type: type,
      name: name
    })

    :ok
  end

  @impl true
  def stop_span, do: :ok
  @impl true
  def set_metadata(_type, _metadata), do: :ok
  @impl true
  def set_error(_error, _opts), do: :ok
end

if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.Test.RowSecurityObanMigration do
    @moduledoc false
    use Ecto.Migration
    def change, do: Oban.Migrations.up(prefix: "row_security_oban")
  end
end

defmodule AshHooks.Test.RowSecurityCases do
  @moduledoc false
  import ExUnit.Assertions
  require Ash.Tracer
  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]
  alias Ash.Resource.Info

  alias AshHooks.{
    Delivery,
    Dispatcher,
    Endpoint,
    EndpointHealth,
    Ingress,
    OutboundAttempt,
    OutboundEvent,
    PrimaryKey
  }

  alias AshHooks.KeyRegistry.Transitions
  alias AshHooks.Test.RealReceiver
  alias Spark.Dsl.Transformer

  def setup_postgres(namespace, repo, read_repo) do
    owner = AshHooks.TestPostgres.Repo
    suffix = Integer.to_string(System.unique_integer([:positive]))
    role = "row_security_" <> suffix
    password = Base.encode16(:crypto.strong_rand_bytes(32))

    owner.query!("CREATE ROLE #{role} LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '#{password}'", [],
      log: false
    )

    on_exit(fn -> owner.query!("DROP ROLE #{role}", [], log: false) end)

    for module <- [repo, read_repo] do
      config =
        owner.config()
        |> Keyword.merge(username: role, password: password, pool_size: 1, log: false)

      Application.put_env(:ash_hooks, module, config)
      {:ok, pid} = module.start_link()
      Process.unlink(pid)

      on_exit(fn ->
        Supervisor.stop(pid)
        Application.delete_env(:ash_hooks, module)
      end)
    end

    ctx = fixtures(namespace, AshPostgres.DataLayer, owner, repo, read_repo)

    for resource <- ctx.resources do
      table = table(resource)
      owner.query!("GRANT SELECT, INSERT, UPDATE, DELETE ON #{table} TO #{role}", [], log: false)
      owner.query!("ALTER TABLE #{table} ENABLE ROW LEVEL SECURITY", [], log: false)
      owner.query!("ALTER TABLE #{table} FORCE ROW LEVEL SECURITY", [], log: false)

      owner.query!("""
      CREATE POLICY tenant_isolation ON #{table}
      USING (tenant_id = current_setting('ash_hooks_test.tenant', true))
      WITH CHECK (tenant_id = current_setting('ash_hooks_test.tenant', true))
      """)
    end

    owner.query!("CREATE SCHEMA row_security_oban", [], log: false)

    :ok =
      Ecto.Migrator.up(owner, 1, AshHooks.Test.RowSecurityObanMigration,
        prefix: "row_security_oban",
        log: false
      )

    owner.query!("GRANT USAGE ON SCHEMA row_security_oban TO #{role}", [], log: false)
    owner.query!("GRANT ALL ON ALL TABLES IN SCHEMA row_security_oban TO #{role}", [], log: false)

    owner.query!("GRANT USAGE ON ALL SEQUENCES IN SCHEMA row_security_oban TO #{role}", [],
      log: false
    )

    owner.query!("ALTER TABLE row_security_oban.oban_jobs ENABLE ROW LEVEL SECURITY", [],
      log: false
    )

    owner.query!("ALTER TABLE row_security_oban.oban_jobs FORCE ROW LEVEL SECURITY", [],
      log: false
    )

    owner.query!(
      """
      CREATE POLICY tenant_isolation ON row_security_oban.oban_jobs
      USING (args->>'tenant' = current_setting('ash_hooks_test.tenant', true))
      WITH CHECK (args->>'tenant' = current_setting('ash_hooks_test.tenant', true))
      """,
      [],
      log: false
    )

    on_exit(fn -> owner.query!("DROP SCHEMA row_security_oban CASCADE", [], log: false) end)
    Map.put(ctx, :role, role)
  end

  def setup_sqlite(namespace, read_repo) do
    repo = Module.concat(namespace, :Repo)

    for module <- [repo, read_repo] do
      path = Path.join(System.tmp_dir!(), "row_security_#{Ash.UUID.generate()}.sqlite3")
      Application.put_env(:ash_hooks, module, database: path, pool_size: 1, log: false)
      {:ok, pid} = module.start_link()
      Process.unlink(pid)

      on_exit(fn ->
        Supervisor.stop(pid)
        Application.delete_env(:ash_hooks, module)
        remove_sqlite_files(path)
      end)
    end

    fixtures(namespace, AshSqlite.DataLayer, repo, repo, read_repo)
  end

  defp remove_sqlite_files(path) do
    for suffix <- ["", "-wal", "-shm"], do: File.rm(path <> suffix)
  end

  defp fixtures(namespace, layer, owner, repo, read_repo) do
    ctx = %{
      namespace: namespace,
      layer: layer,
      owner: owner,
      repo: repo,
      read_repo: read_repo,
      endpoint: Module.concat(namespace, :Endpoint),
      delivery: Module.concat(namespace, :Delivery),
      subscription: Module.concat(namespace, :Subscription),
      emitter: Module.concat(namespace, :Emitter),
      attempt: Module.concat(namespace, :Attempt),
      event_log: Module.concat(namespace, :EventLog),
      inbound: Module.concat(namespace, :Inbound),
      worker: Module.concat(namespace, :Worker),
      registry: Module.concat(namespace, :Registry),
      custody_owner: Module.concat(namespace, :CustodyOwner),
      custodian:
        if(layer == AshPostgres.DataLayer,
          do: AshHooks.TestPostgres.Custodian,
          else: AshHooks.Test.Custodian
        ),
      domain: Module.concat(namespace, :Domain)
    }

    Code.compile_quoted(
      quote do
        defmodule unquote(ctx.domain) do
          use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

          resources do
            allow_unregistered? true
          end
        end
      end
    )

    compile_resource(ctx, ctx.registry, [AshHooks.KeyRegistry], quote(do: nil))

    compile_resource(
      ctx,
      ctx.custody_owner,
      [AshHooks.Endpoint],
      quote do
        endpoint do
          custodian unquote(ctx.custodian)
          key_registry unquote(ctx.registry)
          key_lifecycle(:on)
        end
      end
    )

    compile_resource(
      ctx,
      ctx.endpoint,
      [AshHooks.Endpoint],
      quote do
        endpoint do
          key_lifecycle(:on)

          auto_disable do
            min_attempts(1)
            warning_min_attempts(1)
          end
        end
      end
    )

    compile_resource(
      ctx,
      ctx.delivery,
      [AshHooks.OutboundDelivery],
      quote do
        outbound_delivery do
          resend_tracking(:on)
          test_tracking(:on)
        end
      end
    )

    compile_resource(
      ctx,
      ctx.subscription,
      [AshHooks.Subscription],
      quote do
        subscription do
          endpoint_resource unquote(ctx.endpoint)
        end
      end
    )

    compile_resource(ctx, ctx.attempt, [AshHooks.OutboundAttempt], quote(do: nil))
    compile_resource(ctx, ctx.event_log, [AshHooks.OutboundEvent], quote(do: nil))

    compile_resource(
      ctx,
      ctx.inbound,
      [AshHooks, AshHooks.InboundDelivery],
      quote do
        inbound_delivery do
          ingress_tracking(:on)
        end

        webhooks do
          inbound :event do
            provider(AshHooks.Test.RowSecurityProvider)
            secret {AshHooks.Test.RowSecurityCases, :secret, []}
          end
        end
      end
    )

    if Code.ensure_loaded?(Oban) do
      Code.compile_quoted(
        quote do
          defmodule unquote(ctx.worker) do
            use AshHooks.Worker,
              deliveries: unquote(ctx.delivery),
              endpoints: unquote(ctx.endpoint),
              attempts: unquote(ctx.attempt),
              secret_resolver: {AshHooks.Test.RowSecurityCases, :secret},
              destination_policy: {AshHooks.Test.RowSecurityCases, :allow},
              oban: unquote(Module.concat(namespace, :Oban)),
              http_opts: [validate_destination: false]
          end
        end
      )
    end

    Code.compile_quoted(
      quote do
        defmodule unquote(ctx.emitter) do
          use Ash.Resource,
            domain: unquote(ctx.domain),
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshHooks]

          webhooks do
            outbound :event do
              subscriptions(unquote(ctx.subscription))
              deliveries(unquote(ctx.delivery))
              events(unquote(ctx.event_log))
            end
          end
        end
      end
    )

    resources = [
      ctx.endpoint,
      ctx.delivery,
      ctx.subscription,
      ctx.attempt,
      ctx.event_log,
      ctx.inbound,
      ctx.registry,
      ctx.custody_owner
    ]

    for resource <- resources do
      create_table(owner, resource, layer)
      if layer == AshSqlite.DataLayer, do: create_table(read_repo, resource, layer)
    end

    ctx.custodian.setup_store!()

    on_exit(fn -> drop_fixtures(ctx, resources) end)

    Map.put(ctx, :resources, resources)
  end

  defp drop_fixtures(ctx, resources) do
    ctx.custodian.drop_store!()

    for resource <- Enum.reverse(resources) do
      ctx.owner.query!("DROP TABLE #{table(resource)}")

      if ctx.layer == AshSqlite.DataLayer,
        do: ctx.read_repo.query!("DROP TABLE #{table(resource)}")
    end

    for module <- resources ++ [ctx.worker, ctx.emitter, ctx.domain] do
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp compile_resource(ctx, module, extensions, body) do
    storage = if ctx.layer == AshPostgres.DataLayer, do: :postgres, else: :sqlite
    name = "row_security_" <> Macro.underscore(List.last(Module.split(module)))
    repo = ctx.repo
    read_repo = ctx.read_repo

    storage =
      {storage, [],
       [
         [
           do:
             quote do
               table unquote(name)
               repo(&unquote(__MODULE__).repo/2)
             end
         ]
       ]}

    timestamps =
      if AshHooks.KeyRegistry in extensions, do: quote(do: nil), else: quote(do: timestamps())

    defaults =
      if module == ctx.subscription,
        do: [:destroy, create: :*, update: :*],
        else: [:read, :destroy, create: :*, update: :*]

    paginated_read =
      if module == ctx.subscription do
        quote do
          actions do
            read :read do
              primary? true

              pagination do
                required? true
                offset? true
                default_limit 1
              end
            end
          end
        end
      else
        quote do: nil
      end

    Application.put_env(:ash_hooks, module, {repo, read_repo})

    Code.compile_quoted(
      quote do
        defmodule unquote(module) do
          use Ash.Resource,
            domain: unquote(ctx.domain),
            data_layer: unquote(ctx.layer),
            extensions: unquote(extensions)

          unquote(storage)

          attributes do
            attribute :tenant_id, :string, allow_nil?: false
            unquote(timestamps)
          end

          multitenancy do
            strategy :attribute
            attribute :tenant_id
          end

          actions do
            defaults unquote(defaults)
          end

          unquote(paginated_read)
          unquote(body)
        end
      end
    )

    on_exit(fn -> Application.delete_env(:ash_hooks, module) end)
  end

  def repo(resource, operation) do
    module =
      if is_atom(resource),
        do: resource,
        else: Transformer.get_persisted(resource, :module)

    {mutate, read} = Application.fetch_env!(:ash_hooks, module)

    if operation == :read and Application.get_env(:ash_hooks, :row_security_split, false),
      do: read,
      else: mutate
  end

  defp create_table(repo, resource, layer) do
    columns =
      Enum.map(Info.attributes(resource), fn attr ->
        "#{attr.name} #{sql_type(Ash.Type.storage_type(attr.type, attr.constraints), layer)}" <>
          if(attr.primary_key?, do: " PRIMARY KEY", else: "")
      end)

    repo.query!("CREATE TABLE #{table(resource)} (#{Enum.join(columns, ", ")})")

    for identity <- Info.identities(resource) do
      keys = [:tenant_id | identity.keys] |> Enum.uniq() |> Enum.join(", ")

      repo.query!(
        "CREATE UNIQUE INDEX #{table(resource)}_#{identity.name} ON #{table(resource)} (#{keys})"
      )
    end
  end

  defp sql_type({:array, type}, AshPostgres.DataLayer),
    do: sql_type(type, AshPostgres.DataLayer) <> "[]"

  defp sql_type({:array, _}, AshSqlite.DataLayer), do: "TEXT"
  defp sql_type(:uuid, AshPostgres.DataLayer), do: "UUID"
  defp sql_type(:binary, AshPostgres.DataLayer), do: "BYTEA"
  defp sql_type(:map, AshPostgres.DataLayer), do: "JSONB"
  defp sql_type(:boolean, AshPostgres.DataLayer), do: "BOOLEAN"

  defp sql_type(type, AshPostgres.DataLayer) when type in [:utc_datetime, :utc_datetime_usec],
    do: "TIMESTAMP(6)"

  defp sql_type(:boolean, AshSqlite.DataLayer), do: "INTEGER"
  defp sql_type(:integer, _), do: "BIGINT"
  defp sql_type(:binary, AshSqlite.DataLayer), do: "BLOB"
  defp sql_type(_, _), do: "TEXT"

  defp table(resource) do
    info = Module.concat(Ash.DataLayer.data_layer(resource), :Info)
    info.table(resource)
  end

  def clean(ctx) do
    if ctx.layer == AshPostgres.DataLayer do
      ctx.owner.query!("DELETE FROM row_security_oban.oban_jobs", [], log: false)
    end

    Application.put_env(:ash_hooks, :row_security_split, ctx[:configuration] == :split)
    on_exit(fn -> Application.delete_env(:ash_hooks, :row_security_split) end)
    for resource <- ctx.resources, do: ctx.owner.query!("DELETE FROM #{table(resource)}")
    :ok
  end

  def secret, do: {:ok, Base.encode64(:binary.copy(<<42>>, 32))}
  def secret(_ref), do: secret()
  def allow(_url, _context), do: :allow

  defp seed(ctx, url \\ "https://hooks.example.test/hook") do
    for tenant <- ["tenant_b", "tenant_a"] do
      {:ok, endpoint} =
        Ash.DataLayer.transaction(
          ctx.endpoint,
          fn ->
            endpoint =
              Ash.create!(ctx.endpoint, %{url: url, secret_ref: "key-" <> tenant},
                authorize?: false,
                tenant: tenant
              )

            Ash.create!(ctx.subscription, %{endpoint_id: endpoint.id, event_types: ["event"]},
              authorize?: false,
              tenant: tenant
            )

            endpoint
          end,
          nil,
          %{type: :custom, tenant: tenant, metadata: %{}}
        )

      {tenant, endpoint}
    end
  end

  def outbound_phases(ctx) do
    seeded = seed(ctx)

    for {tenant, _endpoint} <- seeded do
      {:ok, event} = AshHooks.Event.new(type: :event, payload: Jason.encode!(%{tenant: tenant}))

      assert {:ok, [%{status: :deferred}]} =
               Dispatcher.dispatch(ctx.emitter, :event, event, tenant: tenant)
    end

    for {tenant, endpoint} <- seeded do
      assert {:ok, %{records: [row]}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert row.tenant_id == tenant
      assert row.endpoint_id == endpoint.id
      assert {:ok, %{records: [logged]}} = OutboundEvent.list(ctx.event_log, tenant: tenant)
      assert logged.event_uuid == row.event_uuid

      config = [
        deliveries: ctx.delivery,
        endpoints: ctx.endpoint,
        attempts: ctx.attempt,
        destination_policy: fn _, _ -> :deny end
      ]

      assert :ok =
               Delivery.run(
                 %{"delivery_pk" => PrimaryKey.encode(row), "tenant" => tenant},
                 config
               )

      assert {:ok, %{records: [attempt]}} = OutboundAttempt.list(ctx.attempt, tenant: tenant)
      assert attempt.tenant_id == tenant

      assert {:ok, %{attempts: 1}} =
               EndpointHealth.stats(ctx.attempt, endpoint_id: endpoint.id, tenant: tenant)

      assert {:ok, %{warned: 1, disabled: 0}} =
               EndpointHealth.sweep(ctx.endpoint, ctx.attempt, tenant: tenant)

      assert {:ok, rolled} =
               Endpoint.roll_secret(endpoint, new_secret_ref: "next-" <> tenant, tenant: tenant)

      assert {:error, :overlap_active} =
               Endpoint.roll_secret(rolled, new_secret_ref: "blocked-" <> tenant, tenant: tenant)

      assert {:ok, scheduled} =
               Endpoint.schedule_previous_retirement(
                 rolled,
                 DateTime.add(DateTime.utc_now(), 3600),
                 tenant: tenant
               )

      assert {:ok, retired} = Endpoint.expire_previous_secret(scheduled, tenant: tenant)
      assert retired.previous_secret_ref == nil
      assert {:ok, 0} = Endpoint.expire_previous_secrets(ctx.endpoint, tenant: tenant)

      assert {:ok, %{delivery: synthetic}} =
               Delivery.test_send(endpoint, Keyword.merge(config, type: :event, tenant: tenant))

      assert synthetic.tenant_id == tenant

      assert {:ok, %{count: 2}} =
               Delivery.replay(ctx.delivery,
                 endpoints: ctx.endpoint,
                 requested_by: "operator",
                 status: [:dead_letter],
                 dry_run: true,
                 tenant: tenant
               )

      assert {:ok, %{status: :resent}} =
               Delivery.resend(synthetic,
                 requested_by: "operator",
                 endpoints: ctx.endpoint,
                 tenant: tenant
               )

      assert {:ok, _} =
               Dispatcher.reconcile_pending(ctx.emitter, :event,
                 tenant: tenant,
                 older_than: DateTime.add(DateTime.utc_now(), 60)
               )

      assert {:ok, %{count: 1}} =
               OutboundEvent.replay(ctx.event_log, endpoint,
                 deliveries: ctx.delivery,
                 endpoints: ctx.endpoint,
                 declaration: {ctx.emitter, :event},
                 event_type: "event",
                 requested_by: "operator",
                 dry_run: true,
                 tenant: tenant
               )

      assert {:ok, _} =
               OutboundEvent.replay(ctx.event_log, endpoint,
                 deliveries: ctx.delivery,
                 endpoints: ctx.endpoint,
                 declaration: {ctx.emitter, :event},
                 event_type: "event",
                 requested_by: "operator",
                 tenant: tenant
               )

      assert {:ok, %{records: pending}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert length(pending) == 2

      for pending_row <- pending do
        assert pending_row.tenant_id == tenant

        assert :ok =
                 Delivery.run(
                   %{"tenant" => tenant, "delivery_pk" => PrimaryKey.encode(pending_row)},
                   config
                 )
      end

      assert {:ok, %{disabled: 1, warned: 0}} =
               EndpointHealth.sweep(ctx.endpoint, ctx.attempt,
                 tenant: tenant,
                 now: DateTime.add(DateTime.utc_now(), 61)
               )

      assert {:ok, 2} =
               Delivery.prune(ctx.delivery,
                 older_than: DateTime.add(DateTime.utc_now(), 60),
                 attempts: ctx.attempt,
                 tenant: tenant
               )

      assert {:ok, %{records: []}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert {:ok, %{records: []}} = OutboundAttempt.list(ctx.attempt, tenant: tenant)

      assert {:ok, 1} =
               OutboundEvent.prune(ctx.event_log,
                 older_than: DateTime.add(DateTime.utc_now(), 60),
                 tenant: tenant
               )

      assert {:ok, %{records: []}} = OutboundEvent.list(ctx.event_log, tenant: tenant)
    end

    for {_tenant, endpoint} <- seeded do
      assert %{rows: [[1]]} =
               ctx.owner.query!(
                 "SELECT count(*) FROM #{table(ctx.endpoint)} WHERE id = '#{endpoint.id}'"
               )
    end
  end

  def subscription_pages(ctx) do
    seeded = seed(ctx)

    endpoints =
      for {tenant, endpoint} <- seeded do
        {:ok, second} =
          Ash.DataLayer.transaction(
            ctx.endpoint,
            fn ->
              second =
                Ash.create!(ctx.endpoint, %{url: endpoint.url, secret_ref: "second-" <> tenant},
                  tenant: tenant,
                  authorize?: false
                )

              Ash.create!(ctx.subscription, %{endpoint_id: second.id, event_types: ["event"]},
                tenant: tenant,
                authorize?: false
              )

              second
            end,
            nil,
            %{type: :custom, metadata: %{}, tenant: tenant}
          )

        {tenant, [endpoint.id, second.id]}
      end

    for {tenant, ids} <- endpoints do
      {:ok, event} = AshHooks.Event.new(type: :event, payload: Jason.encode!(%{tenant: tenant}))
      assert {:ok, results} = Dispatcher.dispatch(ctx.emitter, :event, event, tenant: tenant)
      assert Enum.sort(Enum.map(results, & &1.endpoint_id)) == Enum.sort(ids)
      assert Enum.all?(results, &(&1.status == :deferred))
      assert {:ok, %{records: rows}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert length(rows) == 2
      assert Enum.all?(rows, &(&1.tenant_id == tenant and &1.endpoint_id in ids))
    end
  end

  def enqueue_repair(ctx) do
    for {tenant, endpoint} <- seed(ctx) do
      {:ok, event} = AshHooks.Event.new(type: :event, payload: Jason.encode!(%{tenant: tenant}))

      config = [
        deliveries: ctx.delivery,
        endpoints: ctx.endpoint,
        destination_policy: fn _, _ -> :deny end
      ]

      invalid_enqueue = fn row, _event ->
        result =
          Delivery.run(
            %{"tenant" => tenant, "delivery_pk" => PrimaryKey.encode(row)},
            Keyword.put(config, :retryable_statuses, :invalid)
          )

        assert result == {:error, :invalid_retryable_statuses}
        result
      end

      assert {:ok, [%{status: :enqueue_failed, error: "unclassified"}]} =
               Dispatcher.dispatch(ctx.emitter, :event, event,
                 tenant: tenant,
                 enqueue: invalid_enqueue,
                 enqueue_key: "repair"
               )

      assert {:ok, %{records: [%{status: :enqueue_failed, tenant_id: ^tenant}]}} =
               Delivery.list(ctx.delivery, tenant: tenant)

      enqueue = fn row, _event ->
        Delivery.run(%{"tenant" => tenant, "delivery_pk" => PrimaryKey.encode(row)}, config)
      end

      assert {:ok, [%{status: :created}]} =
               Dispatcher.dispatch(ctx.emitter, :event, event,
                 tenant: tenant,
                 enqueue: enqueue,
                 enqueue_key: "repair"
               )

      assert {:ok, %{records: [%{status: :dead_letter, tenant_id: ^tenant}]}} =
               Delivery.list(ctx.delivery, tenant: tenant)

      {:ok, unbound} = create_driver_row(ctx, tenant, endpoint)
      route = "bound-" <> tenant
      assert {:ok, bound} = AshHooks.Worker.bind_route(unbound, route, tenant)
      assert bound.dispatch_route == route
      assert bound.tenant_id == tenant
      assert {:ok, reloaded} = AshHooks.Worker.bind_route(unbound, route, tenant)
      assert reloaded.id == bound.id
      assert reloaded.dispatch_route == route
      assert reloaded.tenant_id == tenant
    end
  end

  def inbound_phases(ctx) do
    seeds =
      for tenant <- ["tenant_b", "tenant_a"] do
        env = %{
          tenant: tenant,
          name: :event,
          external_event_id: "event-" <> tenant,
          type_string: "event",
          payload: %{"type" => "event"},
          digest: "digest",
          scope: %{}
        }

        {:ok, true, row} = Ingress.ingest_delivery(ctx.inbound, env)
        {tenant, row, env}
      end

    for {tenant, row, env} <- seeds do
      assert {:ok, false, duplicate} = Ingress.ingest_delivery(ctx.inbound, env)
      assert duplicate.id == row.id
      assert {:ok, token, claimed} = Ingress.claim_delivery(ctx.inbound, row.id, tenant: tenant)
      assert claimed.tenant_id == tenant
      assert :ok = Ingress.renew(ctx.inbound, row.id, token, tenant: tenant)
      assert :ok = Ingress.mark_failed(ctx.inbound, row.id, token, "retry", false, tenant: tenant)
      assert {:ok, token, _} = Ingress.claim_delivery(ctx.inbound, row.id, tenant: tenant)
      assert :ok = Ingress.mark_processed(ctx.inbound, row.id, token, tenant: tenant)

      malformed =
        %{env | external_event_id: "malformed-" <> tenant, payload: %{}}
        |> Map.put(:decode_result, {:error, :malformed_payload})

      assert {:ok, true, bad} = Ingress.ingest_delivery(ctx.inbound, malformed)
      assert bad.status == :failed_permanent
      assert {:ok, %{records: rows}} = Ingress.list(ctx.inbound, tenant: tenant)
      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([row.id, bad.id])
      assert Enum.all?(rows, &(&1.tenant_id == tenant))
      assert {:ok, _} = Ingress.counts(ctx.inbound, tenant: tenant)
      assert {:ok, 0} = Ingress.reap(ctx.inbound, tenant: tenant)
      assert {:ok, _} = Ingress.plan_legacy_identity_adoption(ctx.inbound, :event, tenant: tenant)

      assert {:ok, %{audit: audit}} =
               Ingress.adopt_legacy_identity(ctx.inbound, :event, tenant: tenant, quiesced?: true)

      assert Enum.sort(Enum.map(audit, & &1.before_key["id"])) == Enum.sort([row.id, bad.id])

      raw = Jason.encode!(%{type: "event", id: tenant})
      {:ok, key} = secret()
      signature = :crypto.mac(:hmac, :sha256, key, raw) |> Base.encode16(case: :lower)

      assert {:ok, :created, %{status: :processed} = processed} =
               Ingress.ingest(ctx.inbound, :event, raw, %{
                 tenant: tenant,
                 headers: %{"x-signature" => signature}
               })

      assert processed.tenant_id == tenant

      {:ok, true, recoverable} =
        Ingress.ingest_delivery(
          ctx.inbound,
          %{env | external_event_id: "recovery-" <> tenant}
        )

      {:ok, _, claimed} = Ingress.claim_delivery(ctx.inbound, recoverable.id, tenant: tenant)
      change_fixture(claimed, %{lease_expires_at: DateTime.add(DateTime.utc_now(), -60)}, tenant)
      assert {:ok, 1} = Ingress.reap(ctx.inbound, tenant: tenant)

      assert {:error, _} =
               Ingress.ingest(ctx.inbound, :event, "{}", %{tenant: tenant, signature: "bad"})

      assert {:ok,
              %{
                received: 4,
                processed: 3,
                duplicates: 1,
                failed_verification: 1,
                handler_failures: 1
              }} = Ingress.counts(ctx.inbound, tenant: tenant)

      assert {:ok, %{records: all_rows}} = Ingress.list(ctx.inbound, tenant: tenant)
      assert length(all_rows) == 5
      assert Enum.all?(all_rows, &(&1.tenant_id == tenant))

      assert {:ok, count} =
               Ingress.prune(ctx.inbound,
                 older_than: DateTime.add(DateTime.utc_now(), 60),
                 tenant: tenant
               )

      assert count == 4
      assert {:ok, %{records: [retained]}} = Ingress.list(ctx.inbound, tenant: tenant)
      assert retained.tenant_id == tenant
      assert retained.status == :failed_verification

      assert retained.external_event_id ==
               "verify:" <> (:crypto.hash(:sha256, "{}") |> Base.encode16(case: :lower))
    end
  end

  def worker_phases(ctx) do
    start_supervised!(
      {Oban,
       name: Module.concat(ctx.namespace, :Oban),
       repo: ctx.repo,
       prefix: "row_security_oban",
       queues: false,
       plugins: [],
       engine: Oban.Engines.Basic,
       testing: :disabled}
    )

    receiver = RealReceiver.open!()
    on_exit(fn -> RealReceiver.close!(receiver) end)
    seeded = seed(ctx, RealReceiver.url(receiver))
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:row_security, :begin],
      fn _, _, metadata, _ -> send(parent, {:binding, self(), metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {tenant, _endpoint} <- seeded do
      {:ok, event} = AshHooks.Event.new(type: :event, payload: Jason.encode!(%{tenant: tenant}))

      assert {:ok, [%{status: :created}]} =
               Dispatcher.dispatch(ctx.emitter, :event, event,
                 tenant: tenant,
                 enqueue: {ctx.worker, :enqueue}
               )
    end

    for {tenant, endpoint} <- seeded do
      {:ok, %{records: [row]}} = Delivery.list(ctx.delivery, tenant: tenant)

      {:ok, args} =
        Ash.DataLayer.transaction(
          ctx.delivery,
          fn ->
            assert %{rows: [[args]]} =
                     ctx.repo.query!(
                       "SELECT args FROM row_security_oban.oban_jobs",
                       [],
                       log: false
                     )

            assert args["tenant"] == tenant
            assert args["delivery_pk"] == PrimaryKey.encode(row)
            assert args["endpoint_id"] == endpoint.id
            assert Enum.count(Map.keys(args), &String.contains?(&1, "tenant")) == 1
            args
          end,
          nil,
          %{type: :custom, tenant: tenant, metadata: %{}}
        )

      drain_bindings()

      result = ctx.worker.perform(struct(Oban.Job, args: args))
      assert result == :ok, inspect({result, Delivery.list(ctx.delivery, tenant: tenant)})
      bindings = drain_bindings()
      assert bindings != []
      assert Enum.any?(bindings, fn {pid, _} -> pid != parent end)

      assert Enum.all?(bindings, fn {_, binding} ->
               binding.tenant == tenant and binding.setting == args["tenant"]
             end)

      assert {:ok, %{records: [%{status: :succeeded, attempts: 1}]}} =
               Delivery.list(ctx.delivery, tenant: tenant)

      assert {:ok, %{records: [%{signing_key_ref: ref}]}} =
               OutboundAttempt.list(ctx.attempt, tenant: tenant)

      assert ref == endpoint.secret_ref
    end

    requests = RealReceiver.requests!(receiver)
    assert length(requests) == 2
  end

  def driver_state_phases(ctx) do
    receiver = RealReceiver.open!(status: 410)
    on_exit(fn -> RealReceiver.close!(receiver) end)

    for {tenant, endpoint} <- seed(ctx, RealReceiver.url(receiver)) do
      {:ok, row} = create_driver_row(ctx, tenant, endpoint)

      config = [
        deliveries: ctx.delivery,
        endpoints: ctx.endpoint,
        attempts: ctx.attempt,
        secret_resolver: {__MODULE__, :secret},
        destination_policy: {__MODULE__, :allow},
        http_opts: [validate_destination: false]
      ]

      assert :ok =
               Delivery.run(
                 %{"delivery_pk" => PrimaryKey.encode(row), "tenant" => tenant},
                 config
               )

      assert {:ok, %{records: [%{status: :dead_letter, last_error: "gone_410"}]}} =
               Delivery.list(ctx.delivery, tenant: tenant)

      assert {:ok, %{records: [%{response_status: 410, tenant_id: ^tenant}]}} =
               OutboundAttempt.list(ctx.attempt, tenant: tenant)

      assert {:ok, :ok} =
               Ash.transact(
                 ctx.endpoint,
                 fn ->
                   current =
                     Ash.get!(ctx.endpoint, endpoint.id,
                       tenant: tenant,
                       authorize?: false,
                       context: %{data_layer: %{repo: ctx.repo}}
                     )

                   refute Endpoint.enabled?(current)
                   assert current.secret_first_used_at != nil
                   :ok
                 end,
                 tenant: tenant
               )

      {:ok, exhausted} = create_driver_row(ctx, tenant, endpoint)
      exhausted = change_fixture(exhausted, %{attempts: 10}, tenant)

      assert :ok =
               Delivery.run(
                 %{"delivery_pk" => PrimaryKey.encode(exhausted), "tenant" => tenant},
                 config
               )

      assert {:ok, %{records: rows}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert Enum.any?(rows, &(&1.id == exhausted.id and &1.last_error == "attempt_ceiling"))
      assert Enum.all?(rows, &(&1.tenant_id == tenant))
    end

    assert length(RealReceiver.requests!(receiver)) == 2
  end

  defp drain_bindings(acc \\ []) do
    receive do
      {:binding, pid, metadata} -> drain_bindings([{pid, metadata} | acc])
    after
      0 -> acc
    end
  end

  def unbound_access(ctx) do
    seed(ctx)
    assert %{rows: [[2]]} = ctx.owner.query!("SELECT count(*) FROM #{table(ctx.endpoint)}")

    assert %{rows: [[false, false]]} =
             ctx.repo.query!(
               "SELECT rolsuper, rolbypassrls FROM pg_roles WHERE rolname = current_user"
             )

    for resource <- ctx.resources do
      assert %{rows: [[true, true, true]]} =
               ctx.repo.query!(
                 "SELECT relrowsecurity, relforcerowsecurity, relowner <> (SELECT oid FROM pg_roles WHERE rolname = current_user) FROM pg_class WHERE oid = $1::text::regclass",
                 [table(resource)],
                 log: false
               )
    end

    assert %{rows: [[0]]} = ctx.repo.query!("SELECT count(*) FROM #{table(ctx.endpoint)}")
    assert %{rows: [[0]]} = ctx.read_repo.query!("SELECT count(*) FROM #{table(ctx.endpoint)}")

    assert %{rows: [[nil]]} =
             ctx.repo.query!("SELECT nullif(current_setting('ash_hooks_test.tenant', true), '')")
  end

  def tracer_context(ctx) do
    {context, parent} = trace_context()

    assert_raise RuntimeError, "traced failure", &traced_failure/0

    for {tenant, endpoint} <- seed(ctx) do
      {:ok, row} = create_driver_row(ctx, tenant, endpoint)

      assert :ok =
               Delivery.run(%{"delivery_pk" => PrimaryKey.encode(row), "tenant" => tenant},
                 deliveries: ctx.delivery,
                 endpoints: ctx.endpoint,
                 destination_policy: fn _, _ -> :deny end
               )

      assert_receive {:span, %{pid: child, context: ^context}} when child != parent

      assert {:error, :endpoint_not_live} =
               Delivery.test_send(
                 struct(ctx.endpoint, id: Ash.UUID.generate()),
                 type: :event,
                 deliveries: ctx.delivery,
                 tenant: tenant
               )
    end
  end

  @spec traced_failure() :: no_return()
  defp traced_failure do
    Ash.Tracer.span :custom, "row security tracer", Application.get_env(:ash, :tracer) do
      raise "traced failure"
    end
  end

  def tracer_deadline(ctx) do
    {context, parent} = trace_context()
    receiver = RealReceiver.open!(delay: 2)
    on_exit(fn -> RealReceiver.close!(receiver) end)

    for {tenant, endpoint} <- seed(ctx, RealReceiver.url(receiver)) do
      {:ok, row} = create_driver_row(ctx, tenant, endpoint)
      started = System.monotonic_time(:millisecond)

      assert :ok =
               Delivery.run(%{"delivery_pk" => PrimaryKey.encode(row), "tenant" => tenant},
                 deliveries: ctx.delivery,
                 endpoints: ctx.endpoint,
                 secret_resolver: {__MODULE__, :secret},
                 destination_policy: {__MODULE__, :allow},
                 http_opts: [validate_destination: false],
                 max_attempts: 1,
                 attempt_timeout: 500,
                 finalization_allowance: 2000
               )

      assert System.monotonic_time(:millisecond) - started < 2000
      spans = drain_spans()
      children = spans |> Enum.reject(&(&1.pid == parent)) |> Enum.map(& &1.pid) |> Enum.uniq()
      assert length(children) == 2
      assert Enum.all?(spans, &(&1.context == context))
      assert {:ok, %{records: rows}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert [%{id: id, status: :dead_letter, last_error: "attempt_timeout"}] = rows
      assert id == row.id
    end
  end

  defp drain_spans(acc \\ []) do
    receive do
      {:span, metadata} -> drain_spans([metadata | acc])
    after
      0 -> acc
    end
  end

  defp trace_context do
    tracer = AshHooks.Test.RowSecurityTracer
    previous = Application.get_env(:ash, :tracer)
    Application.put_env(:ash, :tracer, tracer)
    on_exit(fn -> Application.put_env(:ash, :tracer, previous) end)
    context = make_ref()
    tracer.set_span_context(context)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:row_security, :span],
      fn _, _, metadata, _ -> send(parent, {:span, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {context, parent}
  end

  defp create_driver_row(ctx, tenant, endpoint) do
    Ash.DataLayer.transaction(
      ctx.delivery,
      fn ->
        Ash.create!(
          ctx.delivery,
          %{
            event_uuid: Ash.UUID.generate(),
            event_type: "event",
            payload: "{}",
            endpoint_id: endpoint.id
          },
          action: :dispatch,
          authorize?: false,
          tenant: tenant
        )
      end,
      nil,
      %{type: :custom, metadata: %{}, tenant: tenant}
    )
  end

  def registry_phases(ctx) do
    kind = {:standard_webhooks, :v1}

    seeded =
      for tenant <- ["tenant_b", "tenant_a"] do
        {:ok, issued} =
          Transitions.issue(ctx.custody_owner, kind, tenant: tenant)

        assert :ok = ctx.custodian.store(issued.ref, :binary.copy(<<42>>, 32), tenant, kind)

        {:ok, owner} =
          Ash.DataLayer.transaction(
            ctx.custody_owner,
            fn ->
              ctx.custody_owner
              |> Ash.Changeset.for_create(
                :create,
                %{url: "https://hooks.example.test/hook", secret_ref: issued.ref},
                tenant: tenant,
                authorize?: false
              )
              |> Ash.Changeset.force_change_attribute(:secret_kind, kind)
              |> Ash.create!(authorize?: false)
            end,
            nil,
            %{type: :custom, metadata: %{}, tenant: tenant}
          )

        {tenant, issued, owner}
      end

    for {tenant, issued, owner} <- seeded do
      assert {:ok, attached} =
               Transitions.attach(ctx.custody_owner, issued.ref, tenant: tenant)

      assert attached.tenant_id == tenant
      assert {:ok, []} = AshHooks.KeyRegistry.pending(ctx.registry, tenant: tenant)

      assert {:error, :not_destroy_failed} =
               AshHooks.KeyRegistry.rearm(ctx.registry, issued.ref, tenant: tenant)

      assert {:ok, %{retired: 0, destroyed: 0}} =
               AshHooks.KeyRegistry.sweep(ctx.registry, tenant: tenant)

      assert {:ok, _} = Endpoint.expire_previous_secrets(ctx.custody_owner, tenant: tenant)
      assert owner.secret_ref == issued.ref

      assert {:ok, 0} =
               AshHooks.KeyRegistry.prune(ctx.registry,
                 before: DateTime.utc_now(),
                 tenant: tenant
               )

      assert {:ok, rolled} =
               Endpoint.roll_secret(owner, new_secret_ref: "next-" <> tenant, tenant: tenant)

      assert rolled.previous_secret_ref == issued.ref
      assert rolled.previous_secret_kind == kind
      now = DateTime.utc_now()

      assert {:ok, scheduled} =
               Endpoint.schedule_previous_retirement(rolled, now, tenant: tenant, now: now)

      assert scheduled.previous_secret_ref == issued.ref

      assert {:ok, 1} =
               Endpoint.expire_previous_secrets(ctx.custody_owner, tenant: tenant, now: now)

      assert {:ok, %{retired: 0, destroyed: 1}} =
               AshHooks.KeyRegistry.sweep(ctx.registry, tenant: tenant)

      {:ok, replacement} =
        Transitions.issue(ctx.custody_owner, kind, tenant: tenant)

      assert :ok = ctx.custodian.store(replacement.ref, :binary.copy(<<42>>, 32), tenant, kind)
      change_fixture(rolled, %{secret_ref: replacement.ref, secret_kind: kind}, tenant)

      assert {:ok, %{ref: ref}} =
               Transitions.attach(ctx.custody_owner, replacement.ref, tenant: tenant)

      assert ref == replacement.ref

      assert {:ok, :ok} =
               Ash.DataLayer.transaction(
                 ctx.custody_owner,
                 fn ->
                   Ash.destroy(owner,
                     authorize?: false,
                     tenant: tenant,
                     context: %{data_layer: %{repo: ctx.repo}}
                   )
                 end,
                 nil,
                 %{type: :custom, metadata: %{}, tenant: tenant}
               )

      assert {:ok, %{retired: 1, destroyed: 1, destroy_failed: 0}} =
               AshHooks.KeyRegistry.sweep(ctx.registry, tenant: tenant)

      assert {:ok, 2} =
               AshHooks.KeyRegistry.prune(ctx.registry,
                 before: DateTime.add(DateTime.utc_now(), 60),
                 tenant: tenant
               )

      {:ok, failed} =
        Transitions.issue(ctx.custody_owner, kind, tenant: tenant)

      assert :ok =
               ctx.custodian.store(failed.ref, :binary.copy(<<42>>, 32), "other-" <> tenant, kind)

      assert {:ok, %{retired: 1, destroyed: 0, destroy_failed: 1}} =
               AshHooks.KeyRegistry.sweep(ctx.registry,
                 tenant: tenant,
                 now: DateTime.add(DateTime.utc_now(), 3600)
               )

      assert {:ok, [pending]} = AshHooks.KeyRegistry.pending(ctx.registry, tenant: tenant)
      assert pending.ref == failed.ref
      assert pending.tenant_id == tenant
      assert {:ok, rearmed} = AshHooks.KeyRegistry.rearm(ctx.registry, failed.ref, tenant: tenant)
      assert rearmed.destroy_generation == pending.destroy_generation + 1
      assert rearmed.state == :retired
      assert {:ok, []} = AshHooks.KeyRegistry.pending(ctx.registry, tenant: tenant)
    end
  end

  defp change_fixture(row, attrs, tenant) do
    changeset =
      row
      |> Ash.Changeset.for_update(:update, %{}, tenant: tenant, authorize?: false)
      |> Ash.Changeset.force_change_attributes(attrs)

    {:ok, changed} =
      Ash.DataLayer.transaction(
        row.__struct__,
        fn ->
          Ash.update!(changeset,
            authorize?: false,
            context: %{data_layer: %{repo: repo(row.__struct__, :mutate)}}
          )
        end,
        nil,
        %{type: :custom, metadata: %{}, tenant: tenant}
      )

    changed
  end

  def joined_phase_error(ctx, failure) do
    for {tenant, endpoint} <- seed(ctx) do
      assert {:ok, [first, second]} =
               Ash.DataLayer.transaction(
                 ctx.delivery,
                 fn ->
                   first = host_delivery(ctx, endpoint, tenant)
                   assert_pre_write_error(ctx, tenant, failure)
                   second = host_delivery(ctx, endpoint, tenant)
                   [first.id, second.id]
                 end,
                 nil,
                 %{type: :custom, tenant: tenant, metadata: %{}}
               )

      assert {:ok, %{records: rows}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert Enum.sort(Enum.map(rows, & &1.id)) == Enum.sort([first, second])
      assert Enum.all?(rows, &(&1.tenant_id == tenant))
    end
  end

  defp assert_pre_write_error(ctx, tenant, :refusal) do
    assert {:error, :not_destroy_failed} =
             AshHooks.KeyRegistry.rearm(ctx.registry, "missing", tenant: tenant)
  end

  defp assert_pre_write_error(ctx, tenant, :read_error) do
    assert {:error, _error} =
             AshHooks.Phase.run(ctx.delivery, tenant, fn query ->
               query
               |> Ash.Query.add_error("read refused")
               |> Ash.read(authorize?: false, tenant: tenant)
             end)
  end

  def joined_write_failure(ctx) do
    for {tenant, endpoint} <- seed(ctx) do
      failed_event = Ash.UUID.generate()
      host_event = Ash.UUID.generate()

      assert {:error, _error} =
               Ash.DataLayer.transaction(
                 ctx.delivery,
                 fn ->
                   host_delivery(ctx, endpoint, tenant, host_event)

                   failing_package_write(ctx, endpoint, tenant, failed_event)

                   :host_continued
                 end,
                 nil,
                 %{type: :custom, tenant: tenant, metadata: %{}}
               )

      assert_receive {:written_events, events}
      assert Enum.sort(events) == Enum.sort([host_event, failed_event])
      assert {:ok, %{records: []}} = Delivery.list(ctx.delivery, tenant: tenant)
    end
  end

  defp failing_package_write(ctx, endpoint, tenant, event_uuid) do
    AshHooks.Phase.run(ctx.delivery, tenant, fn ->
      ctx.delivery
      |> Ash.Changeset.for_create(:dispatch, delivery_input(endpoint, event_uuid),
        authorize?: false,
        tenant: tenant
      )
      |> Ash.Changeset.after_action(fn _changeset, _row -> fail_after_write(ctx, tenant) end)
      |> Ash.create(authorize?: false, rollback_on_error?: true)
    end)
  end

  defp fail_after_write(ctx, tenant) do
    {:ok, %{records: rows}} = Delivery.list(ctx.delivery, tenant: tenant)
    send(self(), {:written_events, Enum.map(rows, & &1.event_uuid)})
    {:error, "failure after package write"}
  end

  defp host_delivery(ctx, endpoint, tenant, event_uuid \\ Ash.UUID.generate()) do
    Ash.create!(ctx.delivery, delivery_input(endpoint, event_uuid),
      action: :dispatch,
      authorize?: false,
      tenant: tenant
    )
  end

  defp delivery_input(endpoint, event_uuid) do
    %{
      event_uuid: event_uuid,
      event_type: "event",
      payload: "{}",
      endpoint_id: endpoint.id
    }
  end

  def transaction_lifetime(ctx) do
    seeded = seed(ctx)
    parent = self()
    handler = {__MODULE__, make_ref()}

    :telemetry.attach(
      handler,
      [:row_security, :begin],
      fn _, _, metadata, _ -> send(parent, {:binding, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {tenant, endpoint} <- seeded do
      assert {:ok, :ok} =
               Ash.DataLayer.transaction(
                 ctx.endpoint,
                 fn ->
                   assert {:ok, %{records: []}} = Delivery.list(ctx.delivery, tenant: tenant)

                   assert {:ok, rolled} =
                            Endpoint.roll_secret(endpoint,
                              new_secret_ref: "next-" <> tenant,
                              tenant: tenant
                            )

                   assert rolled.tenant_id == tenant
                   :ok
                 end,
                 nil,
                 %{type: :custom, tenant: tenant, metadata: %{}}
               )

      assert_receive {:binding, %{tenant: ^tenant, setting: ^tenant}}
      refute_receive {:binding, _}, 20

      assert %{rows: [[nil]]} =
               ctx.repo.query!(
                 "SELECT nullif(current_setting('ash_hooks_test.tenant', true), '')"
               )

      assert {:error, :intentional_rollback} =
               Ash.DataLayer.transaction(
                 ctx.delivery,
                 fn ->
                   Ash.create!(
                     ctx.delivery,
                     %{
                       event_uuid: Ash.UUID.generate(),
                       event_type: "event",
                       payload: "{}",
                       endpoint_id: endpoint.id
                     },
                     action: :dispatch,
                     authorize?: false,
                     tenant: tenant
                   )

                   Ash.DataLayer.rollback(ctx.delivery, :intentional_rollback)
                 end,
                 nil,
                 %{type: :custom, tenant: tenant, metadata: %{}}
               )

      assert_receive {:binding, %{tenant: ^tenant, setting: ^tenant}}

      assert %{rows: [[nil]]} =
               ctx.repo.query!(
                 "SELECT nullif(current_setting('ash_hooks_test.tenant', true), '')"
               )

      assert {:ok, %{records: []}} = Delivery.list(ctx.delivery, tenant: tenant)
      assert_receive {:binding, %{tenant: ^tenant, setting: ^tenant}}
    end
  end

  def inline_refusal(ctx) do
    for {tenant, _endpoint} <- seed(ctx) do
      assert {:ok, :ok} =
               Ash.DataLayer.transaction(
                 ctx.delivery,
                 fn ->
                   assert_inline_refusal(ctx, tenant)
                 end,
                 nil,
                 %{type: :custom, tenant: tenant, metadata: %{}}
               )
    end
  end

  defp assert_inline_refusal(ctx, tenant) do
    {:ok, event} =
      AshHooks.Event.new(type: :event, payload: Jason.encode!(%{tenant: tenant}))

    enqueue = fn row, _event ->
      Delivery.run(%{"tenant" => tenant, "delivery_pk" => PrimaryKey.encode(row)},
        deliveries: ctx.delivery,
        endpoints: ctx.endpoint,
        attempt_timeout: 50,
        finalization_allowance: 50
      )
    end

    assert {:ok, [%{status: :enqueue_failed}]} =
             Dispatcher.dispatch(ctx.emitter, :event, event,
               tenant: tenant,
               enqueue: enqueue,
               enqueue_key: "inline"
             )

    query = Ash.Query.set_context(ctx.delivery, %{data_layer: %{repo: ctx.repo}})

    assert [%{status: :pending, attempts: 0}] =
             Ash.read!(query, authorize?: false, tenant: tenant)

    :ok
  end

  def inherited_refusal(ctx, operation) do
    seeded = seed(ctx)

    for {tenant, _endpoint} <- seeded do
      {:ok, event} = AshHooks.Event.new(type: :event, payload: Jason.encode!(%{tenant: tenant}))

      assert {:ok, [%{status: :deferred}]} =
               Dispatcher.dispatch(ctx.emitter, :event, event, tenant: tenant)
    end

    for {tenant, endpoint} <- seeded do
      assert {:ok, :ok} =
               Ash.transact(
                 ctx.delivery,
                 fn ->
                   assert_inherited_refusal(ctx, tenant, endpoint, operation)
                 end,
                 tenant: tenant
               )
    end
  end

  defp assert_inherited_refusal(ctx, tenant, endpoint, operation) do
    assert {:ok, %{records: [row]}} = Delivery.list(ctx.delivery, tenant: tenant)
    parent = self()

    enqueue = fn candidate, _event ->
      result =
        Delivery.run(
          %{"tenant" => tenant, "delivery_pk" => PrimaryKey.encode(candidate)},
          deliveries: ctx.delivery,
          endpoints: ctx.endpoint,
          attempt_timeout: 50,
          finalization_allowance: 50
        )

      send(parent, {:inline_driver_result, candidate.id, result})
      result
    end

    refusal_operation(operation, ctx, tenant, endpoint, row, enqueue)

    assert {:ok, %{records: [pending]}} =
             Delivery.list(ctx.delivery, tenant: tenant)

    assert pending.tenant_id == tenant
    assert pending.endpoint_id == endpoint.id
    assert pending.status == :pending
    assert pending.attempts == 0
    assert pending.enqueue_token == nil
    assert pending.enqueue_lease_expires_at == nil

    if operation in [:reconcile, :public_reconcile],
      do: assert(pending.last_error == "inside_transaction")

    if operation != :worker do
      id = pending.id
      assert_receive {:inline_driver_result, ^id, {:error, :inside_transaction}}
    end

    :ok
  end

  defp refusal_operation(:resend, ctx, tenant, _endpoint, row, enqueue) do
    terminal = change_fixture(row, %{status: :dead_letter}, tenant)

    assert {:ok,
            %{
              status: :resent,
              delivery: %{status: :pending},
              enqueue: {:error, :inside_transaction}
            }} =
             Delivery.resend(terminal,
               endpoints: ctx.endpoint,
               requested_by: "operator",
               tenant: tenant,
               enqueue: enqueue
             )
  end

  defp refusal_operation(:delivery_replay, ctx, tenant, _endpoint, row, enqueue) do
    change_fixture(row, %{status: :dead_letter}, tenant)

    assert {:ok, %{resent: 1, skipped: 0}} =
             Delivery.replay(ctx.delivery,
               endpoints: ctx.endpoint,
               requested_by: "operator",
               status: [:dead_letter],
               tenant: tenant,
               enqueue: enqueue
             )
  end

  defp refusal_operation(operation, ctx, tenant, endpoint, row, enqueue)
       when operation in [:event_replay, :event_replay_missing] do
    if operation == :event_replay_missing do
      Ash.destroy!(row, authorize?: false, tenant: tenant)
    else
      change_fixture(row, %{status: :dead_letter}, tenant)
    end

    expected =
      if operation == :event_replay_missing,
        do: %{created: 1, re_sent: 0, skipped: 0},
        else: %{created: 0, re_sent: 1, skipped: 0}

    assert {:ok, ^expected} =
             OutboundEvent.replay(ctx.event_log, endpoint,
               deliveries: ctx.delivery,
               endpoints: ctx.endpoint,
               declaration: {ctx.emitter, :event},
               event_type: "event",
               requested_by: "operator",
               tenant: tenant,
               enqueue: enqueue,
               enqueue_key: "inline"
             )
  end

  defp refusal_operation(operation, ctx, tenant, _endpoint, _row, enqueue)
       when operation in [:reconcile, :public_reconcile] do
    module = if operation == :reconcile, do: Dispatcher, else: AshHooks

    assert {:ok, [%{status: :enqueue_failed, error: "inside_transaction"}]} =
             module.reconcile_pending(ctx.emitter, :event,
               tenant: tenant,
               enqueue: enqueue,
               enqueue_key: "inline",
               older_than: DateTime.add(DateTime.utc_now(), 60)
             )
  end

  defp refusal_operation(:worker, ctx, tenant, _endpoint, row, _enqueue) do
    assert {:error, :inside_transaction} =
             ctx.worker.perform(
               struct(Oban.Job,
                 args: %{"tenant" => tenant, "delivery_pk" => PrimaryKey.encode(row)}
               )
             )
  end

  def driver_refusal(ctx) do
    for tenant <- ["tenant_b", "tenant_a"] do
      assert {:ok, :ok} =
               Ash.DataLayer.transaction(
                 ctx.delivery,
                 fn ->
                   assert_driver_refusal(ctx, tenant)
                 end,
                 nil,
                 %{type: :custom, tenant: tenant, metadata: %{}}
               )
    end
  end

  defp assert_driver_refusal(ctx, tenant) do
    assert Ash.DataLayer.in_transaction?(ctx.delivery)

    row =
      Ash.create!(
        ctx.delivery,
        %{
          event_uuid: Ash.UUID.generate(),
          event_type: "event",
          payload: "{}",
          endpoint_id: Ash.UUID.generate()
        },
        action: :dispatch,
        authorize?: false,
        tenant: tenant
      )

    query = Ash.Query.set_context(ctx.delivery, %{data_layer: %{repo: ctx.repo}})

    before =
      Enum.map(
        Ash.read!(query, authorize?: false, tenant: tenant),
        &PrimaryKey.encode/1
      )

    parent = self()
    collector = spawn(fn -> collect_process_traces(parent) end)
    on_exit(fn -> Process.exit(collector, :kill) end)
    :erlang.trace(parent, true, [:procs, {:tracer, collector}])
    probe = spawn(fn -> :ok end)
    assert_receive {:guard_trace, {:trace, ^parent, :spawn, ^probe, _}}
    handler = {__MODULE__, make_ref()}
    event = ctx.repo.config()[:telemetry_prefix] ++ [:query]

    :telemetry.attach(
      handler,
      event,
      fn _, _, _, _ -> send(parent, :guard_query) end,
      nil
    )

    try do
      ctx.repo.query!("SELECT 1", [], log: false)
      assert_receive :guard_query

      assert {:error, :inside_transaction} =
               Delivery.run(
                 %{"tenant" => tenant, "delivery_pk" => PrimaryKey.encode(row)},
                 deliveries: ctx.delivery,
                 endpoints: ctx.endpoint,
                 attempt_timeout: 50,
                 finalization_allowance: 50
               )

      assert {:error, :inside_transaction} =
               Delivery.test_send(struct(ctx.endpoint, id: row.endpoint_id),
                 type: :event,
                 deliveries: ctx.delivery,
                 tenant: tenant
               )
    after
      :erlang.trace(parent, false, [:procs])
      :telemetry.detach(handler)
    end

    delivered = :erlang.trace_delivered(parent)
    assert_receive {:trace_delivered, ^parent, ^delivered}
    send(collector, {:finish, delivered})
    assert_receive {:guard_trace_finished, ^delivered}
    refute_received {:guard_trace, {:trace, ^parent, :spawn, _, _}}
    refute_received :guard_query

    assert before ==
             Enum.map(
               Ash.read!(query, authorize?: false, tenant: tenant),
               &PrimaryKey.encode/1
             )

    assert Ash.get!(ctx.delivery, row.id,
             authorize?: false,
             tenant: tenant,
             context: %{data_layer: %{repo: ctx.repo}}
           ).status ==
             :pending

    :ok
  end

  defp collect_process_traces(parent) do
    receive do
      {:finish, delivered} ->
        send(parent, {:guard_trace_finished, delivered})

      event ->
        send(parent, {:guard_trace, event})
        collect_process_traces(parent)
    end
  end
end
