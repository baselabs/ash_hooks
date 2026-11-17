Code.require_file("outbox_process.exs", __DIR__)
Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.OutboxAcceptance do
  @moduledoc false
  import ExUnit.Assertions

  def setup(namespace) do
    sqlite? = namespace == AshHooks.OutboxFixtures.SQLite

    repo =
      if sqlite?,
        do: AshHooks.OutboxFixtures.SQLiteRepo,
        else: AshHooks.OutboxFixtures.Postgres.Repo

    owner = if sqlite?, do: repo, else: AshHooks.TestPostgres.Repo
    database = Path.join(System.tmp_dir!(), "outbox_#{Ash.UUID.generate()}.sqlite3")

    if sqlite? do
      Application.put_env(:ash_hooks, repo,
        database: database,
        pool_size: 5,
        journal_mode: :wal,
        busy_timeout: 5_000
      )

      {:ok, pid} = repo.start_link()
      Process.unlink(pid)
    end

    resources =
      Map.new([:endpoint, :subscription, :delivery, :outbox, :emitter], fn name ->
        {name, Module.concat(namespace, name |> Atom.to_string() |> Macro.camelize())}
      end)

    create_tables(resources, owner, sqlite?)

    roles = if sqlite?, do: nil, else: setup_roles(resources, repo, owner)
    oban_options = setup_oban(namespace, repo, owner, roles, sqlite?)

    fixture =
      Map.merge(resources, %{
        repo: repo,
        owner: owner,
        roles: roles,
        namespace: namespace,
        sqlite?: sqlite?,
        database: database,
        oban_options: oban_options
      })

    ExUnit.Callbacks.on_exit(fn -> cleanup(fixture) end)
    fixture
  end

  defp create_tables(resources, owner, sqlite?) do
    Enum.each(resources, fn {_name, resource} ->
      table = table(resource)

      fields =
        Enum.map_join(
          Ash.Resource.Info.attributes(resource),
          ", ",
          &column(&1, resource == resources.outbox, sqlite?)
        )

      owner.query!("CREATE TABLE #{table} (#{fields})")
    end)

    owner.query!(
      "CREATE UNIQUE INDEX #{table(resources.outbox)}_unique_publication_index ON #{table(resources.outbox)} (org_id, event_uuid)"
    )

    owner.query!(
      "CREATE UNIQUE INDEX #{table(resources.delivery)}_unique_delivery_index ON #{table(resources.delivery)} (org_id, endpoint_id, event_uuid)"
    )

    info = if sqlite?, do: AshSqlite.DataLayer.Info, else: AshPostgres.DataLayer.Info

    for index <- info.custom_indexes(resources.outbox) do
      name =
        table(resources.outbox) <>
          "_" <> Enum.map_join(index.fields, "_", &to_string/1) <> "_index"

      fields = Enum.map_join(index.fields, ", ", &("\"" <> to_string(&1) <> "\""))

      owner.query!(
        "CREATE INDEX #{name} ON #{table(resources.outbox)} (#{fields}) WHERE #{index.where}"
      )
    end
  end

  defp column(attr, outbox?, sqlite?) do
    type =
      if not sqlite? and outbox? and attr.name == :metadata,
        do: "JSON",
        else: sql_type(Ash.Type.storage_type(attr.type, attr.constraints), sqlite?)

    "\"#{attr.name}\" #{type}" <> if(attr.primary_key?, do: " PRIMARY KEY", else: "")
  end

  defp cleanup(fixture) do
    %{
      oban_options: oban_options,
      namespace: namespace,
      sqlite?: sqlite?,
      owner: owner,
      repo: repo,
      roles: roles,
      database: database
    } = fixture

    resources = Map.take(fixture, [:endpoint, :subscription, :delivery, :outbox, :emitter])

    if oban_options do
      name = Keyword.fetch!(oban_options, :name)
      if pid = Oban.whereis(name), do: Supervisor.stop(pid)

      if engine = Oban.whereis(Module.concat(namespace, :EngineOban)),
        do: Supervisor.stop(engine)

      if sqlite?,
        do: owner.query!("DROP TABLE oban_jobs"),
        else: owner.query!("DROP SCHEMA outbox_acceptance_oban CASCADE")
    end

    Enum.each(resources, fn {_name, resource} ->
      owner.query!("DROP TABLE #{table(resource)}")
    end)

    Application.delete_env(:ash_hooks, Module.concat(namespace, :Runtime))

    Supervisor.stop(Process.whereis(repo))
    Application.delete_env(:ash_hooks, repo)

    if sqlite? do
      Enum.each(["", "-shm", "-wal"], &File.rm(database <> &1))
    else
      engine_repo = AshHooks.OutboxFixtures.Postgres.EngineRepo
      Supervisor.stop(Process.whereis(engine_repo))
      Application.delete_env(:ash_hooks, engine_repo)
      for role <- Map.values(roles), do: owner.query!("DROP ROLE #{role}", [], log: false)
    end
  end

  def clean(fixture) do
    for key <- [:outbox, :delivery, :subscription, :endpoint, :emitter] do
      fixture.owner.query!("DELETE FROM #{table(fixture[key])}")
    end

    if fixture.oban_options do
      prefix = if fixture.sqlite?, do: "", else: "outbox_acceptance_oban."
      fixture.owner.query!("DELETE FROM #{prefix}oban_jobs")
    end

    Application.delete_env(:ash_hooks, Module.concat(fixture.namespace, :Runtime))
    :ok
  end

  defp setup_oban(namespace, repo, owner, roles, sqlite?) do
    if Code.ensure_loaded?(Oban) do
      if sqlite? do
        repo.query!("""
        CREATE TABLE oban_jobs (
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
      else
        owner.query!("CREATE SCHEMA outbox_acceptance_oban")

        :ok =
          Ecto.Migrator.up(owner, 2_026_111_701, AshHooks.OutboxFixtures.ObanMigration,
            prefix: "outbox_acceptance_oban",
            log: false
          )
      end

      unless sqlite?, do: setup_oban_roles(owner, roles)

      options = [
        name: Module.concat(namespace, :Oban),
        repo: repo,
        engine: if(sqlite?, do: Oban.Engines.Lite, else: Oban.Engines.Basic),
        queues: false,
        plugins: [],
        peer: false,
        stage_interval: :infinity,
        testing: :disabled
      ]

      options =
        if sqlite?,
          do: options,
          else:
            Keyword.merge(options, prefix: "outbox_acceptance_oban", notifier: Oban.Notifiers.PG)

      {:ok, pid} = Oban.start_link(options)
      Process.unlink(pid)

      unless sqlite? do
        engine_options =
          Keyword.merge(options,
            repo: AshHooks.OutboxFixtures.Postgres.EngineRepo,
            name: Module.concat(namespace, :EngineOban)
          )

        {:ok, engine} = Oban.start_link(engine_options)
        Process.unlink(engine)
      end

      options
    end
  end

  defp setup_oban_roles(owner, roles) do
    for role <- Map.values(roles) do
      owner.query!("GRANT USAGE ON SCHEMA outbox_acceptance_oban TO #{role}", [], log: false)

      owner.query!(
        "GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA outbox_acceptance_oban TO #{role}",
        [],
        log: false
      )

      owner.query!(
        "GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA outbox_acceptance_oban TO #{role}",
        [],
        log: false
      )
    end

    for table <- ["oban_jobs", "oban_peers"] do
      relation = "outbox_acceptance_oban.#{table}"
      owner.query!("ALTER TABLE #{relation} ENABLE ROW LEVEL SECURITY")
      owner.query!("ALTER TABLE #{relation} FORCE ROW LEVEL SECURITY")

      owner.query!(
        "CREATE POLICY engine_access ON #{relation} TO #{roles.engine} USING (true) WITH CHECK (true)"
      )
    end

    owner.query!(
      "CREATE POLICY tenant_jobs ON outbox_acceptance_oban.oban_jobs TO #{roles.runtime} USING (args->>'tenant' = current_setting('outbox_acceptance.tenant', true)) WITH CHECK (args->>'tenant' = current_setting('outbox_acceptance.tenant', true))"
    )
  end

  defp setup_roles(resources, repo, owner) do
    suffix = Integer.to_string(System.unique_integer([:positive]))
    roles = %{runtime: "outbox_runtime_#{suffix}", engine: "outbox_engine_#{suffix}"}

    for {kind, role} <- roles do
      password = Base.encode16(:crypto.strong_rand_bytes(32))

      owner.query!("CREATE ROLE #{role} LOGIN NOSUPERUSER NOBYPASSRLS PASSWORD '#{password}'", [],
        log: false
      )

      module = if kind == :runtime, do: repo, else: AshHooks.OutboxFixtures.Postgres.EngineRepo

      Application.put_env(
        :ash_hooks,
        module,
        Keyword.merge(owner.config(),
          username: role,
          password: password,
          pool_size: 5,
          log: false
        )
      )

      {:ok, pid} = module.start_link()
      Process.unlink(pid)
    end

    for {_name, resource} <- resources do
      relation = table(resource)

      owner.query!("GRANT SELECT, INSERT, UPDATE, DELETE ON #{relation} TO #{roles.runtime}", [],
        log: false
      )

      owner.query!("ALTER TABLE #{relation} ENABLE ROW LEVEL SECURITY")
      owner.query!("ALTER TABLE #{relation} FORCE ROW LEVEL SECURITY")

      owner.query!(
        "CREATE POLICY tenant_isolation ON #{relation} TO #{roles.runtime} USING (org_id = current_setting('outbox_acceptance.tenant', true)) WITH CHECK (org_id = current_setting('outbox_acceptance.tenant', true))"
      )
    end

    roles
  end

  def transaction(f, operation) do
    f.repo.transaction(fn ->
      unless f.sqlite?,
        do:
          f.repo.query!("SELECT set_config('outbox_acceptance.tenant', $1, true)", ["tenant-a"],
            log: false
          )

      operation.()
    end)
  end

  def ash_transact(f, operation), do: Ash.transact(f.outbox, operation, tenant: "tenant-a")

  def start_peer(f) do
    {:ok, peer, _node} =
      :peer.start_link(%{
        connection: :standard_io,
        args: [~c"+S", ~c"2", ~c"-pa" | :code.get_path()],
        wait_boot: 30_000
      })

    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:mix])
    :ok = :peer.call(peer, Mix, :env, [:test])
    :ok = :peer.call(peer, Application, :put_all_env, [[ash: Application.get_all_env(:ash)]])

    :peer.call(
      peer,
      Code,
      :require_file,
      [Path.expand("test/ash_hooks/outbox_process.exs")],
      30_000
    )

    :peer.call(
      peer,
      Code,
      :require_file,
      [Path.expand("test/ash_hooks/outbox_resources.exs")],
      30_000
    )

    :ok =
      :peer.call(
        peer,
        AshHooks.OutboxProcess,
        :boot,
        [f.repo, f.repo.config(), f.oban_options],
        30_000
      )

    ExUnit.Callbacks.on_exit(fn -> stop_peer(peer) end)
    peer
  end

  defp stop_peer(peer) do
    :peer.stop(peer)
  catch
    :exit, _reason -> :ok
  end

  def crash(f, stage, event, marker \\ nil) do
    peer = start_peer(f)
    path = Path.join(System.tmp_dir!(), "outbox_checkpoint_#{Ash.UUID.generate()}")

    try do
      :ok =
        :peer.call(peer, AshHooks.OutboxProcess, :execute, [
          f.namespace,
          stage,
          event,
          path,
          marker
        ])

      pid = await_file(path, System.monotonic_time(:millisecond) + 20_000)
      assert {"", 0} = System.cmd("kill", ["-KILL", pid])
      stop_peer(peer)
      pid
    after
      File.rm(path)
      File.rm(path <> ".release")
      File.rm(path <> ".writing")
      stop_peer(peer)
    end
  end

  defp await_file(path, deadline) do
    case File.read(path) do
      {:ok, pid} ->
        pid

      {:error, :enoent} ->
        assert System.monotonic_time(:millisecond) < deadline,
               "OS process did not reach checkpoint"

        Process.sleep(10)
        await_file(path, deadline)
    end
  end

  def expire(f, event) do
    set(f, event.id,
      lease_expires_at: DateTime.add(DateTime.utc_now(), -1, :second),
      next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second)
    )
  end

  def drain(f) do
    Oban.drain_queue(Module.concat(f.namespace, if(f.sqlite?, do: :Oban, else: :EngineOban)),
      queue: :outbox_acceptance,
      with_safety: false
    )
  end

  def table(resource) do
    info = Module.concat(Ash.DataLayer.data_layer(resource), :Info)
    info.table(resource)
  end

  defp sql_type({:array, _}, true), do: "TEXT"
  defp sql_type({:array, _}, false), do: "TEXT[]"
  defp sql_type(:uuid, true), do: "TEXT"
  defp sql_type(:uuid, false), do: "UUID"
  defp sql_type(:binary, true), do: "BLOB"
  defp sql_type(:binary, false), do: "BYTEA"
  defp sql_type(type, _) when type in [:integer, :bigint], do: "BIGINT"
  defp sql_type(:boolean, _), do: "BOOLEAN"
  defp sql_type(:map, true), do: "TEXT"
  defp sql_type(:map, false), do: "JSONB"

  defp sql_type(type, false)
       when type in [:utc_datetime_usec, :utc_datetime, :naive_datetime_usec, :naive_datetime],
       do: "TIMESTAMP(6)"

  defp sql_type(_type, _), do: "TEXT"

  def event(id \\ Ash.UUID.generate(), metadata \\ %{}) do
    {:ok, event} = AshHooks.Event.new(id: id, type: :changed, payload: "body", metadata: metadata)
    event
  end

  def publish(f, event, opts \\ []),
    do:
      AshHooks.publish(
        f.outbox,
        {f.emitter, :changed},
        event,
        Keyword.merge([tenant: "tenant-a"], opts)
      )

  def fanout(f, id), do: AshHooks.fanout(f.outbox, id, tenant: "tenant-a")

  def rows(f, resource, tenant \\ "tenant-a") do
    {:ok, rows} =
      AshHooks.Phase.run(f[resource], tenant, fn ->
        Ash.read(f[resource], authorize?: false, tenant: tenant)
      end)

    rows
  end

  def publication(f, id), do: Enum.find(rows(f, :outbox), &(&1.event_uuid == id))

  def endpoint(f, opts \\ []) do
    input =
      Map.new(
        Keyword.merge(
          [url: "https://receiver.example.test/hook", secret_ref: "key-reference"],
          opts
        )
      )

    endpoint = Ash.create!(f.endpoint, input, authorize?: false, tenant: "tenant-a")

    Ash.create!(f.subscription, %{endpoint_id: endpoint.id, event_types: ["changed"]},
      authorize?: false,
      tenant: "tenant-a"
    )

    endpoint
  end

  def set(f, id, values) do
    args =
      Enum.map(values, fn {name, value} ->
        attribute = Ash.Resource.Info.attribute(f.outbox, name)
        storage = Ash.Type.storage_type(attribute.type, attribute.constraints)

        if not f.sqlite? and storage == :uuid and is_binary(value),
          do: Ecto.UUID.dump!(value),
          else: encode_value(value, f.sqlite?)
      end) ++ [id]

    fields =
      values
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{key, _}, n} -> "#{key} = #{parameter(f, n)}" end)

    f.owner.query!(
      "UPDATE #{table(f.outbox)} SET #{fields} WHERE event_uuid = #{parameter(f, length(args))}",
      args
    )
  end

  defp encode_value(%DateTime{} = value, true), do: DateTime.to_iso8601(value)
  defp encode_value(%DateTime{} = value, false), do: DateTime.to_naive(value)
  defp encode_value(value, true) when is_map(value), do: Jason.encode!(value)
  defp encode_value(value, _sqlite?), do: value

  defp parameter(%{sqlite?: true}, _), do: "?"
  defp parameter(_, n), do: "$#{n}"

  def raw_subscription(f, endpoint, filters, opts \\ []) do
    id = Ash.UUID.generate()
    types = Keyword.get(opts, :types, ["changed"])
    paused = Keyword.get(opts, :paused, false)
    json = if filters == :sql_null, do: nil, else: Jason.encode!(filters)

    if f.sqlite? do
      f.owner.query!(
        "INSERT INTO #{table(f.subscription)} (id, org_id, endpoint_id, event_types, event_filters, paused) VALUES (?, ?, ?, ?, ?, ?)",
        [id, "tenant-a", endpoint.id, Jason.encode!(types), json, if(paused, do: 1, else: 0)]
      )
    else
      f.owner.query!(
        "INSERT INTO #{table(f.subscription)} (id, org_id, endpoint_id, event_types, event_filters, paused) VALUES ($1, $2, $3, $4, $5::text::jsonb, $6)",
        [Ecto.UUID.dump!(id), "tenant-a", Ecto.UUID.dump!(endpoint.id), types, json, paused]
      )
    end

    id
  end

  def entry(f, :raw, operation), do: transaction(f, operation)
  def entry(f, kind, operation), do: apply(Ash, kind, [f.outbox, operation, [tenant: "tenant-a"]])

  def observed(acc) do
    receive do
      {:observed, name, measurements, metadata} ->
        observed([{name, measurements, metadata} | acc])
    after
      0 -> acc
    end
  end

  def count_queries(f, operation) do
    key = {__MODULE__, make_ref()}
    parent = self()

    prefix =
      f.repo.config()[:telemetry_prefix] ||
        Enum.map(Module.split(f.repo), &String.to_atom(Macro.underscore(&1)))

    :telemetry.attach(
      key,
      prefix ++ [:query],
      fn _, _, metadata, _ ->
        if self() == parent, do: send(parent, {key, metadata.query})
      end,
      nil
    )

    try do
      result = operation.()
      {result, collect(key, [])}
    after
      :telemetry.detach(key)
    end
  end

  defp collect(key, acc) do
    receive do
      {^key, sql} -> collect(key, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end

for {module, namespace} <- [
      {AshHooks.OutboxSQLiteTest, AshHooks.OutboxFixtures.SQLite},
      {AshHooks.OutboxPostgresTest, AshHooks.OutboxFixtures.Postgres}
    ] do
  defmodule module do
    use ExUnit.Case, async: false
    require Ash.Query
    alias AshHooks.OutboxAcceptance, as: Cases
    alias AshHooks.Test.HttpReceiver
    @moduletag timeout: 180_000
    @namespace namespace
    if @namespace == AshHooks.OutboxFixtures.Postgres, do: @moduletag(:postgres)

    setup_all do
      {:ok, Cases.setup(@namespace)}
    end

    setup fixture do
      Cases.clean(fixture)
    end

    test "A1 publish and duplicate each use one statement; conflicts preserve the transaction",
         f do
      event = Cases.event()

      assert {:ok, :committed} =
               Cases.transaction(f, fn ->
                 assert {{:ok, :accepted}, first} =
                          Cases.count_queries(f, fn -> Cases.publish(f, event) end)

                 assert length(first) == 1
                 assert hd(first) =~ "ON CONFLICT"

                 assert {{:ok, :duplicate}, duplicate} =
                          Cases.count_queries(f, fn -> Cases.publish(f, event) end)

                 assert length(duplicate) == 1

                 assert {{:error, :publication_conflict}, conflict} =
                          Cases.count_queries(f, fn ->
                            Cases.publish(f, %{event | payload: "different"})
                          end)

                 assert length(conflict) == 1

                 assert {{:error, :unknown_declaration}, []} =
                          Cases.count_queries(f, fn ->
                            AshHooks.publish(f.outbox, {f.emitter, :unknown}, event,
                              tenant: "tenant-a"
                            )
                          end)

                 f.repo.query!("SELECT 1")
                 :committed
               end)

      assert [%{state: :pending, attempts: 0}] = Cases.rows(f, :outbox)
    end

    test "A1 statement counts hold in Ash transactions, the deprecated entry point and actions",
         f do
      for entry <- [:transact, :transaction] do
        event = Cases.event()

        result =
          apply(Ash, entry, [
            f.outbox,
            fn ->
              assert {{:ok, :accepted}, first} =
                       Cases.count_queries(f, fn -> Cases.publish(f, event) end)

              assert length(first) == 1
              original = Cases.publication(f, event.id)

              assert {{:ok, :duplicate}, duplicate} =
                       Cases.count_queries(f, fn -> Cases.publish(f, event) end)

              assert length(duplicate) == 1
              assert Cases.publication(f, event.id).updated_at == original.updated_at
              assert Cases.publication(f, event.id).inserted_at == original.inserted_at
              :ok
            end,
            [tenant: "tenant-a"]
          ])

        assert result == {:ok, :ok}
      end

      {_record, queries} =
        Cases.count_queries(f, fn ->
          Ash.create!(f.emitter, %{value: "action"}, authorize?: false, tenant: "tenant-a")
        end)

      assert length(
               Enum.filter(
                 queries,
                 &String.starts_with?(&1, "INSERT INTO \"#{Cases.table(f.outbox)}\"")
               )
             ) == 1
    end

    test "A1 malformed publications and missing tenants refuse before storage", f do
      event = Cases.event()

      for declaration <- [:changed, {f.emitter, :changed, :extra}] do
        assert {{:error, :unknown_declaration}, []} =
                 Cases.count_queries(f, fn ->
                   AshHooks.publish(f.outbox, declaration, event, tenant: "tenant-a")
                 end)
      end

      for invalid <- [nil, %{}, %{event | type: "other"}, %{event | payload: ""}] do
        assert {{:error, :invalid_event}, []} =
                 Cases.count_queries(f, fn -> Cases.publish(f, invalid) end)
      end

      assert {{:error, :unresolved_route}, []} =
               Cases.count_queries(f, fn -> Cases.publish(f, event, route: :removed) end)

      operations = [
        fn -> AshHooks.publish(f.outbox, {f.emitter, :changed}, event, []) end,
        fn -> AshHooks.fanout(f.outbox, event.id, []) end,
        fn -> AshHooks.fanout_pending(f.outbox, 10, []) end,
        fn -> AshHooks.rearm(f.outbox, event.id, []) end,
        fn -> AshHooks.OutboundOutbox.list(f.outbox, []) end,
        fn -> AshHooks.OutboundOutbox.prune(f.outbox, []) end
      ]

      for operation <- operations do
        assert {{:error, :tenant_required}, []} = Cases.count_queries(f, operation)
      end
    end

    test "A2 nested commits and rollbacks do not leak publications", f do
      event = Cases.event()

      assert {:error, :undo} =
               Cases.transaction(f, fn ->
                 assert {:ok, :accepted} = Cases.publish(f, event)
                 f.repo.rollback(:undo)
               end)

      assert [] = Cases.rows(f, :outbox)

      assert {:ok, :ok} =
               Cases.ash_transact(f, fn ->
                 assert {:ok, :ok} =
                          Cases.ash_transact(f, fn ->
                            assert {:ok, :accepted} = Cases.publish(f, event)
                            :ok
                          end)

                 :ok
               end)

      assert [_] = Cases.rows(f, :outbox)

      assert {:error, :publication_repository_mismatch} =
               Cases.publish(f, Cases.event(), dynamic_repo: self())

      assert {:error, :inside_transaction} =
               Cases.transaction(f, fn -> Cases.fanout(f, event.id) end) |> elem(1)
    end

    test "A2 every transaction entry point rolls back inner and outer action writes", f do
      for outer <- [:raw, :transact, :transaction],
          inner <- [:raw, :transact, :transaction],
          rollback_at <- [:inner, :outer] do
        event = Cases.event()

        result =
          Cases.entry(f, outer, fn ->
            Cases.entry(f, inner, fn ->
              assert {:ok, :accepted} = Cases.publish(f, event)
              Ash.create!(f.emitter, %{value: "nested"}, tenant: "tenant-a", authorize?: false)
              if rollback_at == :inner, do: f.repo.rollback(:undo)
              :ok
            end)

            f.repo.rollback(:undo)
          end)

        assert match?({:error, _}, result)
        assert is_nil(Cases.publication(f, event.id))
        assert Cases.rows(f, :emitter) == []
      end

      for outer <- [:raw, :transact, :transaction], inner <- [:raw, :transact, :transaction] do
        event = Cases.event()

        assert {:ok, :ok} =
                 Cases.entry(f, outer, fn ->
                   assert {:ok, :ok} =
                            Cases.entry(f, inner, fn ->
                              assert {:ok, :accepted} = Cases.publish(f, event)

                              Ash.create!(f.emitter, %{value: "nested"},
                                tenant: "tenant-a",
                                authorize?: false
                              )

                              :ok
                            end)

                   :ok
                 end)

        assert Cases.publication(f, event.id).state == :pending
      end
    end

    test "A3 OS death before commit rolls back and death after commit needs no hint", f do
      before = Cases.event()
      Cases.crash(f, :before_commit, before)
      assert [] = Cases.rows(f, :outbox)
      committed = Cases.event()
      Cases.crash(f, :after_commit, committed)

      assert {:ok, %{done: 1, errors: []}} =
               AshHooks.fanout_pending(f.outbox, 10, tenant: "tenant-a")

      assert Cases.publication(f, committed.id).state == :done
    end

    test "A3 OS death during builders preserves the delivery already written", f do
      for _ <- 1..2, do: Cases.endpoint(f, pinned_payload_version: 1)
      event = Cases.event()
      assert {:ok, :accepted} = Cases.publish(f, event)
      Cases.crash(f, :mid_fanout, event)
      assert [surviving] = Cases.rows(f, :delivery)
      Cases.expire(f, event)

      assert {:ok, %{done: 1, errors: []}} =
               AshHooks.fanout_pending(f.outbox, 10, tenant: "tenant-a")

      assert length(Cases.rows(f, :delivery)) == 2
      assert Enum.any?(Cases.rows(f, :delivery), &(&1.id == surviving.id))
    end

    if Code.ensure_loaded?(Oban) do
      test "A3 OS death around durable admission recovers without a second surviving send", f do
        {server, port} = HttpReceiver.start()
        on_exit(fn -> :inets.stop(:httpd, server) end)
        Cases.endpoint(f, url: "http://localhost:#{port}/200")

        for stage <- [:before_admission, :after_admission] do
          event = Cases.event()
          assert {:ok, :accepted} = Cases.publish(f, event, route: :queued)
          Cases.crash(f, stage, event)

          assert [surviving] =
                   Enum.filter(Cases.rows(f, :delivery), &(&1.event_uuid == event.id))

          if stage == :after_admission do
            assert %{success: 1} = Cases.drain(f)
            assert_receive {:http_received, _request}, 5_000
          else
            # The killed claimant held the real 30-second enqueue lease.
            Process.sleep(30_100)
          end

          Cases.expire(f, event)

          assert {:ok, %{done: 1, errors: []}} =
                   AshHooks.fanout_pending(f.outbox, 10, tenant: "tenant-a")

          assert [%{id: id}] =
                   Enum.filter(Cases.rows(f, :delivery), &(&1.event_uuid == event.id))

          assert id == surviving.id

          if stage == :before_admission do
            assert %{success: 1} = Cases.drain(f)
            assert_receive {:http_received, _request}, 5_000
          else
            assert %{success: 0} = Cases.drain(f)
            refute_receive {:http_received, _request}
          end
        end
      end

      test "A10 generated fanout jobs round trip tenants through a real Oban engine", f do
        runtime = Module.concat(f.namespace, :Runtime)
        worker = Module.concat(f.namespace, :Worker)
        Application.put_env(:ash_hooks, runtime, :oban)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        assert {:ok, :accepted} = Cases.publish(f, event, tenant: "tenant-b")
        prefix = if f.sqlite?, do: "", else: "outbox_acceptance_oban."
        assert %{:rows => jobs} = f.owner.query!("SELECT args FROM #{prefix}oban_jobs")

        args =
          Enum.map(jobs, fn [arg] -> if is_binary(arg), do: Jason.decode!(arg), else: arg end)

        assert Enum.sort(Enum.map(args, & &1["tenant"])) == ["tenant-a", "tenant-b"]
        assert Enum.all?(args, &(&1["kind"] == "fanout"))
        assert %{success: 2} = Cases.drain(f)
        assert [%{state: :done}] = Cases.rows(f, :outbox)
        assert [%{state: :done}] = Cases.rows(f, :outbox, "tenant-b")
        assert {:error, :unknown_source} = worker.enqueue_fanout(%AshHooks.Event{}, "tenant-a")
        assert {:error, :unknown_source} = AshHooks.Worker.perform_fanout(nil, %{})
        assert {:error, :invalid_event} = worker.perform(%Oban.Job{args: %{"kind" => "fanout"}})

        assert {:error, :unknown_source} =
                 worker.perform(%Oban.Job{
                   args: %{
                     "kind" => "fanout",
                     "outbox_resource" => "unknown",
                     "event_uuid" => event.id
                   }
                 })

        pending = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, pending)
        Cases.set(f, pending.id, dispatch_route: "removed")

        job = %Oban.Job{
          args: %{
            "kind" => "fanout",
            "outbox_resource" => Atom.to_string(f.outbox),
            "event_uuid" => pending.id,
            "tenant" => "tenant-a"
          }
        }

        assert :ok = worker.perform(job)
        assert Cases.publication(f, pending.id).state == :pending

        assert {:ok, {:error, :inside_transaction}} =
                 Cases.transaction(f, fn -> worker.perform(job) end)
      end

      test "A14 a restarted process re-admits the original metadata to a named route", f do
        {server, port} = HttpReceiver.start()
        on_exit(fn -> :inets.stop(:httpd, server) end)
        Cases.endpoint(f, url: "http://localhost:#{port}/200")
        marker = Path.join(System.tmp_dir!(), "outbox_admission_#{Ash.UUID.generate()}")
        on_exit(fn -> File.rm(marker) end)
        Application.put_env(:ash_hooks, :outbox_admission_marker, marker)
        on_exit(fn -> Application.delete_env(:ash_hooks, :outbox_admission_marker) end)
        event = Cases.event(Ash.UUID.generate(), %{"admission" => "fail", "region" => "west"})
        assert {:ok, :accepted} = Cases.publish(f, event, route: :queued)
        Cases.crash(f, :admission_failure, event, marker)

        assert [%{status: :pending, last_error: "closed"} = surviving] =
                 Cases.rows(f, :delivery)

        assert File.read!(marker) == "refused"
        Cases.expire(f, event)
        assert :done = Cases.fanout(f, event.id)
        assert [%{id: id}] = Cases.rows(f, :delivery)
        assert id == surviving.id
        assert %{success: 1} = Cases.drain(f)
        assert_receive {:http_received, _request}, 5_000
      end
    end

    test "A4 endpoint failures stay pending and recover without replacing surviving rows", f do
      good = Cases.endpoint(f)
      bad = Cases.endpoint(f, pinned_payload_version: 99)
      event = Cases.event()
      assert {:ok, :accepted} = Cases.publish(f, event)
      assert {:pending, _} = Cases.fanout(f, event.id)
      assert [%{endpoint_id: id}] = Cases.rows(f, :delivery)
      assert id == good.id

      assert %{
               state: :pending,
               attempts: 1,
               next_attempt_at: %DateTime{},
               last_error: "unknown_pinned_version"
             } = Cases.publication(f, event.id)

      Ash.update!(bad, %{pinned_payload_version: 2}, authorize?: false, tenant: "tenant-a")
      Cases.set(f, event.id, next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))
      assert :done = Cases.fanout(f, event.id)
      assert length(Cases.rows(f, :delivery)) == 2
      assert :done = Cases.fanout(f, event.id)
    end

    if @namespace == AshHooks.OutboxFixtures.Postgres do
      test "A4 role-denied reads, rejected inserts and failed state writes are visible", f do
        good = Cases.endpoint(f)
        bad = Cases.endpoint(f, pinned_payload_version: 99)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        assert {:pending, :unknown_pinned_version} = Cases.fanout(f, event.id)
        assert [%{endpoint_id: id}] = Cases.rows(f, :delivery)
        assert id == good.id
        endpoints = Cases.table(f.endpoint)
        f.owner.query!("REVOKE SELECT ON #{endpoints} FROM #{f.roles.runtime}", [], log: false)

        try do
          Cases.expire(f, event)
          assert {:pending, _error} = Cases.fanout(f, event.id)
        after
          f.owner.query!("GRANT SELECT ON #{endpoints} TO #{f.roles.runtime}", [], log: false)
        end

        Ash.update!(bad, %{pinned_payload_version: 2}, authorize?: false, tenant: "tenant-a")
        relation = Cases.table(f.delivery)

        f.owner.query!(
          "ALTER TABLE #{relation} ADD CONSTRAINT reject_one_endpoint CHECK (endpoint_id <> '#{bad.id}'::uuid)"
        )

        try do
          Cases.expire(f, event)
          assert :failed = Cases.fanout(f, event.id)
          assert [%{endpoint_id: ^id}] = Cases.rows(f, :delivery)
        after
          f.owner.query!("ALTER TABLE #{relation} DROP CONSTRAINT reject_one_endpoint")
        end

        assert {:ok, _row} = AshHooks.rearm(f.outbox, event.id, tenant: "tenant-a")
        assert :done = Cases.fanout(f, event.id)
        assert length(Cases.rows(f, :delivery)) == 2
      end

      test "A4 and A13 state-write and candidate-read errors are returned", f do
        Cases.endpoint(f, pinned_payload_version: 99)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        handler = make_ref()

        :ok =
          :telemetry.attach(
            handler,
            [:ash_hooks, :outbox, :claim],
            fn _, _, metadata, _ ->
              if metadata.outcome == :claimed do
                f.owner.query!(
                  "REVOKE UPDATE ON #{Cases.table(f.outbox)} FROM #{f.roles.runtime}",
                  [],
                  log: false
                )
              end
            end,
            nil
          )

        try do
          assert {:error, {:publication_transition_failed, _error}} = Cases.fanout(f, event.id)
        after
          :telemetry.detach(handler)

          f.owner.query!("GRANT UPDATE ON #{Cases.table(f.outbox)} TO #{f.roles.runtime}", [],
            log: false
          )
        end

        f.owner.query!("REVOKE SELECT ON #{Cases.table(f.outbox)} FROM #{f.roles.runtime}", [],
          log: false
        )

        try do
          assert {:error, _error} = AshHooks.fanout_pending(f.outbox, 10, tenant: "tenant-a")
        after
          f.owner.query!("GRANT SELECT ON #{Cases.table(f.outbox)} TO #{f.roles.runtime}", [],
            log: false
          )
        end
      end

      test "A1 and A13 grant failures remain visible at every outbox write entry point", f do
        [pending, failed, done] = events = for _ <- 1..3, do: Cases.event()
        for event <- events, do: assert({:ok, :accepted} = Cases.publish(f, event))
        Cases.set(f, failed.id, state: "failed", failed_at: DateTime.utc_now())

        Cases.set(f, done.id,
          state: "done",
          completed_at: DateTime.add(DateTime.utc_now(), -3_601, :second)
        )

        for privilege <- ["INSERT", "UPDATE", "DELETE"] do
          f.owner.query!(
            "REVOKE #{privilege} ON #{Cases.table(f.outbox)} FROM #{f.roles.runtime}",
            [],
            log: false
          )

          try do
            case privilege do
              "INSERT" ->
                assert {:error, _error} = Cases.publish(f, Cases.event())

              "UPDATE" ->
                assert {:error, _error} = Cases.fanout(f, pending.id)
                assert {:error, _error} = AshHooks.rearm(f.outbox, failed.id, tenant: "tenant-a")

                assert {:ok, %{errors: [_error], done: 0}} =
                         AshHooks.fanout_pending(f.outbox, 10, tenant: "tenant-a")

              "DELETE" ->
                assert {:error, _error} =
                         AshHooks.OutboundOutbox.prune(f.outbox, tenant: "tenant-a")
            end
          after
            f.owner.query!(
              "GRANT #{privilege} ON #{Cases.table(f.outbox)} TO #{f.roles.runtime}",
              [],
              log: false
            )
          end
        end

        assert Cases.publication(f, pending.id).state == :pending
        assert Cases.publication(f, failed.id).state == :failed
        assert Cases.publication(f, done.id).state == :done
      end

      test "A4 denied delivery admission keeps the publication recoverable", f do
        Cases.endpoint(f)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event, route: :queued)

        assert {:ok, [%{status: :created}]} =
                 AshHooks.dispatch(f.emitter, :changed, event,
                   tenant: "tenant-a",
                   enqueue: {Module.concat(f.namespace, :Runtime), :enqueue}
                 )

        relation = Cases.table(f.delivery)
        role = f.roles.runtime
        f.owner.query!("REVOKE UPDATE ON #{relation} FROM #{role}", [], log: false)

        try do
          assert {:pending, _error} = Cases.fanout(f, event.id)
          assert [%{status: :pending}] = Cases.rows(f, :delivery)
        after
          f.owner.query!("GRANT UPDATE ON #{relation} TO #{role}", [], log: false)
        end

        Cases.expire(f, event)
        assert :done = Cases.fanout(f, event.id)
        assert length(Cases.rows(f, :delivery)) == 1
      end

      test "A5 losing the fanout owner kills its blocked SQL runner", f do
        Cases.endpoint(f, pinned_payload_version: 1)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        parent = self()

        locked =
          Task.async(fn ->
            f.owner.transaction(fn ->
              f.owner.query!("LOCK TABLE #{Cases.table(f.delivery)} IN ACCESS EXCLUSIVE MODE")
              send(parent, :locked)

              receive do
                :release -> :ok
              end
            end)
          end)

        assert_receive :locked
        Application.put_env(:ash_hooks, :outbox_observer, self())
        on_exit(fn -> Application.delete_env(:ash_hooks, :outbox_observer) end)

        try do
          owner = spawn(fn -> Cases.fanout(f, event.id) end)
          assert_receive {:outbox_builder, runner}, 5_000
          monitor = Process.monitor(runner)
          Process.exit(owner, :kill)
          assert_receive {:DOWN, ^monitor, :process, ^runner, :killed}, 5_000
          assert Cases.publication(f, event.id).state == :pending

          Cases.expire(f, event)
          call = Task.async(fn -> Cases.fanout(f, event.id) end)
          assert_receive {:outbox_builder, runner}, 5_000
          Process.exit(runner, :kill)
          assert {:pending, :fanout_crashed} = Task.await(call, 5_000)
          assert Cases.publication(f, event.id).last_error == "fanout_crashed"
        after
          send(locked.pid, :release)
          Task.await(locked, 5_000)
        end

        Cases.expire(f, event)
        assert :done = Cases.fanout(f, event.id)
      end

      test "A5 a blocked SQL runner dies and stale ownership emits no result", f do
        refute AshHooks.Info.writable_id?(f.delivery)
        Cases.endpoint(f, pinned_payload_version: 1)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        parent = self()

        locked =
          Task.async(fn ->
            f.owner.transaction(fn ->
              f.owner.query!("LOCK TABLE #{Cases.table(f.delivery)} IN ACCESS EXCLUSIVE MODE")
              send(parent, :locked)

              receive do
                :release -> :ok
              end
            end)
          end)

        assert_receive :locked
        Application.put_env(:ash_hooks, :outbox_observer, self())
        on_exit(fn -> Application.delete_env(:ash_hooks, :outbox_observer) end)
        handler = make_ref()

        :ok =
          :telemetry.attach_many(
            handler,
            [[:ash_hooks, :outbox, :claim], [:ash_hooks, :outbox, :result]],
            fn name, _, metadata, _ -> send(parent, {:outbox_telemetry, name, metadata}) end,
            nil
          )

        try do
          runner_call = Task.async(fn -> Cases.fanout(f, event.id) end)
          assert_receive {:outbox_builder, runner}, 5_000
          ref = Process.monitor(runner)
          Cases.expire(f, event)
          assert_receive {:DOWN, ^ref, :process, ^runner, :killed}, 5_000
          assert :stale = Task.await(runner_call, 5_000)
          assert_receive {:outbox_telemetry, [:ash_hooks, :outbox, :claim], %{outcome: :stale}}
          refute_receive {:outbox_telemetry, [:ash_hooks, :outbox, :result], _}

          sweeps =
            for _ <- 1..2,
                do:
                  Task.async(fn ->
                    AshHooks.fanout_pending(f.outbox, 10, tenant: "tenant-a")
                  end)

          worker = Module.concat(f.namespace, :Worker)
          assert :ok = worker.enqueue_fanout(Cases.publication(f, event.id), "tenant-a")

          reconcile =
            Task.async(fn ->
              AshHooks.reconcile_pending(f.emitter, :changed,
                tenant: "tenant-a",
                enqueue: {Module.concat(f.namespace, :Runtime), :enqueue}
              )
            end)

          Process.sleep(1_200)
          send(locked.pid, :release)
          Task.await(locked, 5_000)
          for task <- sweeps, do: assert({:ok, _summary} = Task.await(task, 10_000))
          assert {:ok, _summary} = Task.await(reconcile, 10_000)
          Cases.expire(f, event)
          assert :done = Cases.fanout(f, event.id)
        after
          :telemetry.detach(handler)
          send(locked.pid, :release)
        end
      end
    end

    if Code.ensure_loaded?(Oban) do
      test "A3 replay preserves durable admission and a live send lease", f do
        Cases.endpoint(f)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event, route: :queued)
        assert :done = Cases.fanout(f, event.id)
        assert [original] = Cases.rows(f, :delivery)
        assert DateTime.compare(original.enqueue_lease_expires_at, DateTime.utc_now()) == :gt

        Cases.set(f, event.id, state: "pending", completed_at: nil)
        assert :done = Cases.fanout(f, event.id)
        assert [replayed] = Cases.rows(f, :delivery)
        assert replayed.id == original.id
        assert replayed.enqueue_lease_expires_at == original.enqueue_lease_expires_at

        lease = DateTime.add(DateTime.utc_now(), 60, :second)
        sql_lease = if f.sqlite?, do: DateTime.to_iso8601(lease), else: DateTime.to_naive(lease)

        sql =
          if f.sqlite?,
            do:
              "UPDATE #{Cases.table(f.delivery)} SET status = 'sending', enqueue_lease_expires_at = NULL, send_lease_expires_at = ? WHERE event_uuid = ?",
            else:
              "UPDATE #{Cases.table(f.delivery)} SET status = 'sending', enqueue_lease_expires_at = NULL, send_lease_expires_at = $1 WHERE event_uuid = $2"

        f.owner.query!(sql, [sql_lease, event.id])
        Cases.set(f, event.id, state: "pending", completed_at: nil)
        assert :done = Cases.fanout(f, event.id)

        assert [%{id: id, status: :sending, send_lease_expires_at: ^lease}] =
                 Cases.rows(f, :delivery)

        assert id == original.id
      end
    end

    test "A6 tenant, route and content ownership remain distinct", f do
      event = Cases.event()

      results =
        1..2
        |> Task.async_stream(
          fn _ ->
            Cases.transaction(f, fn ->
              Cases.count_queries(f, fn -> Cases.publish(f, event) end)
            end)
          end,
          max_concurrency: 2
        )
        |> Enum.map(fn {:ok, {:ok, {result, queries}}} ->
          assert length(queries) == 1
          assert hd(queries) =~ "ON CONFLICT"
          result
        end)

      assert Enum.sort(results) == [ok: :accepted, ok: :duplicate]
      assert {:ok, :accepted} = Cases.publish(f, event, tenant: "tenant-b")
      assert {:error, :publication_conflict} = Cases.publish(f, event, route: :queued)

      assert {:error, :publication_conflict} =
               Cases.publish(f, %{event | metadata: %{"different" => true}})

      assert length(Cases.rows(f, :outbox)) == 1
      assert length(Cases.rows(f, :outbox, "tenant-b")) == 1
      Cases.endpoint(f)
      other = Cases.event()

      assert {:ok, [%{status: :deferred}]} =
               AshHooks.dispatch(f.emitter, :changed, other, tenant: "tenant-a")

      assert {:ok, :accepted} = Cases.publish(f, other)
      assert :done = Cases.fanout(f, other.id)
      assert length(Cases.rows(f, :delivery)) == 1
    end

    test "A7 only completed rows beyond the horizon can be pruned", f do
      events = for _ <- 1..4, do: Cases.event()
      for event <- events, do: assert({:ok, :accepted} = Cases.publish(f, event))
      [pending, leased, failed, done] = events

      Cases.set(f, leased.id,
        claim_token: Ash.UUID.generate(),
        lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
      )

      Cases.set(f, failed.id, state: "failed", failed_at: DateTime.utc_now())
      assert :done = Cases.fanout(f, done.id)
      assert {:ok, 0} = AshHooks.OutboundOutbox.prune(f.outbox, tenant: "tenant-a")

      result =
        Ash.bulk_destroy(f.outbox, :prune, %{},
          authorize?: false,
          tenant: "tenant-a",
          strategy: [:atomic],
          return_records?: true,
          return_errors?: true
        )

      assert result.status == :success
      assert result.records == []
      Cases.set(f, done.id, completed_at: DateTime.add(DateTime.utc_now(), -3_601, :second))
      assert {:ok, 1} = AshHooks.OutboundOutbox.prune(f.outbox, tenant: "tenant-a")

      assert Enum.sort(Enum.map(Cases.rows(f, :outbox), & &1.event_uuid)) ==
               Enum.sort([pending.id, leased.id, failed.id])

      assert {:ok, :accepted} = Cases.publish(f, done)
    end

    test "A8 version-one publications survive a version-two deployment, fresh and partial", f do
      for stage <- [:version_one, :version_one_partial] do
        event = Cases.event()
        pins = if stage == :version_one, do: [nil, 1, 2], else: [nil, 1, 99]
        endpoints = for pin <- pins, do: Cases.endpoint(f, pinned_payload_version: pin)
        Cases.crash(f, stage, event)
        assert Cases.publication(f, event.id).version == 1
        assert AshHooks.Info.outbound(f.emitter, :changed).version == 2
        surviving = Cases.rows(f, :delivery)

        if stage == :version_one_partial do
          assert length(surviving) == 2

          Ash.update!(List.last(endpoints), %{pinned_payload_version: 2},
            tenant: "tenant-a",
            authorize?: false
          )

          Cases.expire(f, event)
        end

        assert :done = Cases.fanout(f, event.id)
        rows = Cases.rows(f, :delivery)

        for {endpoint, expected} <- Enum.zip(endpoints, ["body", "body", "v2:body"]) do
          assert Enum.find(rows, &(&1.endpoint_id == endpoint.id)).payload == expected
        end

        assert Enum.all?(surviving, fn row -> Enum.any?(rows, &(&1.id == row.id)) end)
        Cases.clean(f)
      end
    end

    test "A9 metadata boundaries refuse before SQL and accepted values round trip exactly", f do
      invalid = [
        %{key: true},
        %{"key" => :value},
        %{"key" => self()},
        %{"key" => {1, 2}},
        %{"key" => [1 | 2]},
        %{"key" => DateTime.utc_now()},
        %{"key" => <<255>>},
        %{"key" => <<0>>},
        %{<<0>> => 1},
        %{"key" => -0.0},
        %{"key" => 9_223_372_036_854_775_808},
        %{"key" => -9_223_372_036_854_775_809},
        %{"key" => String.duplicate("a", 1_048_576)},
        %{"key" => Enum.reduce(1..33, nil, fn _, acc -> [acc] end)}
      ]

      for metadata <- invalid do
        event = Cases.event(Ash.UUID.generate(), metadata)

        assert {{:error, :invalid_publication_metadata}, []} =
                 Cases.count_queries(f, fn -> Cases.publish(f, event) end)
      end

      metadata = %{
        "null" => nil,
        "bool" => false,
        "numbers" => [
          -9_223_372_036_854_775_808,
          9_223_372_036_854_775_807,
          1,
          1.0,
          0.0,
          0.0001,
          1.0e20,
          1.797_693_134_862_315_7e308
        ],
        "text" => "unicode λ",
        "nested" => [%{}, %{"x" => true}]
      }

      event = Cases.event(Ash.UUID.generate(), metadata)
      assert {:ok, :accepted} = Cases.publish(f, event)
      assert Cases.publication(f, event.id).metadata === metadata
      assert Cases.publication(f, event.id).metadata == metadata
      assert {:ok, :duplicate} = Cases.publish(f, event)
      assert :done = Cases.fanout(f, event.id)
    end

    test "A9 exact JSON size and depth limits preserve submitted metadata", f do
      overhead = byte_size(Jason.encode!(%{"text" => ""}))
      largest = %{"text" => String.duplicate("x", 1_048_576 - overhead)}
      deepest = %{"value" => Enum.reduce(1..31, true, fn _, acc -> [acc] end)}
      previous = Logger.level()
      Logger.configure(level: :warning)

      try do
        for metadata <- [largest, deepest, %{"smallest" => 5.0e-324}] do
          event = Cases.event(Ash.UUID.generate(), metadata)
          assert {:ok, :accepted} = Cases.publish(f, event)
          assert Cases.publication(f, event.id).metadata === metadata
          assert :done = Cases.fanout(f, event.id)
        end
      after
        Logger.configure(level: previous)
      end
    end

    test "A11 notifications are after commit and trigger failures cannot fail publish", f do
      runtime = Module.concat(f.namespace, :Runtime)
      Application.put_env(:ash_hooks, runtime, self())
      Application.put_env(:ash_hooks, :outbox_host_observer, self())
      on_exit(fn -> Application.delete_env(:ash_hooks, :outbox_host_observer) end)

      assert :ok = AshHooks.OutboundOutbox.Notifier.notify(%Ash.Notifier.Notification{})

      for mode <- [:ignore, :warn, :raise] do
        previous = Application.get_env(:ash, :missed_notifications)
        Application.put_env(:ash, :missed_notifications, mode)

        try do
          event = Cases.event()

          assert {:ok, :ok} =
                   Cases.transaction(f, fn ->
                     assert {:ok, :accepted} = Cases.publish(f, event)
                     refute_receive {:triggered, _, _}
                     :ok
                   end)

          refute_receive {:triggered, _, _}
          assert :done = Cases.fanout(f, event.id)

          for inner <- [:transact, :transaction] do
            nested = Cases.event()

            assert {:ok, {:ok, :ok}} =
                     Cases.transaction(f, fn ->
                       Cases.entry(f, inner, fn ->
                         assert {:ok, :accepted} = Cases.publish(f, nested)
                         refute_receive {:triggered, _, _}
                         :ok
                       end)
                     end)

            refute_receive {:triggered, _, _}
            assert :done = Cases.fanout(f, nested.id)
          end
        after
          if is_nil(previous),
            do: Application.delete_env(:ash, :missed_notifications),
            else: Application.put_env(:ash, :missed_notifications, previous)
        end
      end

      event = Cases.event()

      assert {:ok, :ok} =
               Cases.ash_transact(f, fn ->
                 assert {:ok, :accepted} = Cases.publish(f, event)
                 refute_receive {:triggered, _, _}
                 :ok
               end)

      assert_receive {:triggered, id, "tenant-a"}
      assert id == event.id
      assert_receive {:host_notification, %{data: %{event_uuid: ^id}, metadata: %{host: true}}}
      assert_receive {:host_notification, %{data: %{event_uuid: ^id}, action: %{name: :publish}}}
      assert {:ok, :accepted} = Cases.publish(f, Cases.event(), return_notifications?: true)
      refute_receive {:triggered, _, _}

      for failure <- [:raise, :exit, :throw, :error] do
        Application.put_env(:ash_hooks, runtime, failure)
        assert {:ok, :accepted} = Cases.publish(f, Cases.event())
      end
    end

    test "A12 both dispatch paths select types, pause and 5C filter candidates in SQL", f do
      values = [
        {:sql_null, true},
        {nil, true},
        {%{}, true},
        {%{"region" => "west"}, true},
        {%{"region" => "east"}, false},
        {%{"region" => ["west", "south"]}, true},
        {%{"flag" => true}, true},
        {%{"__invalid__" => true}, true},
        {%{"disabled" => false}, true},
        {%{"nullable" => nil}, true},
        {%{"disabled" => true}, false},
        {%{"nullable" => false}, false},
        {%{"flag" => 1}, false},
        {%{"count" => 1}, true},
        {%{"nested" => %{"value" => true}}, true},
        {%{"region" => %{}}, false},
        {%{"missing" => nil}, false},
        {[], false},
        {"malformed", false},
        {true, false},
        {42, false}
      ]

      expected =
        for {filters, matches?} <- values, reduce: [] do
          ids ->
            endpoint =
              Ash.create!(
                f.endpoint,
                %{url: "https://receiver.example.test/hook", secret_ref: "key-reference"},
                authorize?: false,
                tenant: "tenant-a"
              )

            Cases.raw_subscription(f, endpoint, filters)
            if matches?, do: [endpoint.id | ids], else: ids
        end

      for options <- [[types: ["other"]], [paused: true]] do
        endpoint =
          Ash.create!(
            f.endpoint,
            %{url: "https://receiver.example.test/hook", secret_ref: "key-reference"},
            authorize?: false,
            tenant: "tenant-a"
          )

        Cases.raw_subscription(f, endpoint, %{}, options)
      end

      metadata = %{
        "region" => "west",
        "flag" => true,
        "disabled" => false,
        "nullable" => nil,
        "count" => 1.0,
        "nested" => %{"value" => true},
        "__invalid__" => true
      }

      event = Cases.event(Ash.UUID.generate(), metadata)

      assert {{:ok, results}, queries} =
               Cases.count_queries(f, fn ->
                 AshHooks.dispatch(f.emitter, :changed, event, tenant: "tenant-a")
               end)

      assert Enum.sort(Enum.map(results, & &1.endpoint_id)) == Enum.sort(expected)

      subscription_sql =
        Enum.find(queries, &String.contains?(&1, "FROM \"#{Cases.table(f.subscription)}\""))

      assert subscription_sql =~ if(f.sqlite?, do: "json_each", else: "jsonb_typeof")
      assert subscription_sql =~ if(f.sqlite?, do: "json_each", else: "::text[] &&")
      assert subscription_sql =~ "paused"
      assert {:ok, :accepted} = Cases.publish(f, event)
      assert :done = Cases.fanout(f, event.id)

      assert Enum.sort(Enum.map(Cases.rows(f, :delivery), & &1.endpoint_id)) ==
               Enum.sort(expected)

      for malformed <- [[], "value", true, 1, :invalid] do
        refute AshHooks.Subscription.matches_filters?(
                 struct(f.subscription, event_filters: malformed),
                 metadata
               )
      end
    end

    test "A13 every observable outbox outcome follows its real state transition", f do
      owner = self()
      handler = make_ref()

      events =
        for event <- [:publish, :trigger, :claim, :result, :rearm, :sweep],
            do: [:ash_hooks, :outbox, event]

      :ok =
        :telemetry.attach_many(
          handler,
          events,
          fn name, measurements, metadata, _ ->
            send(owner, {:observed, List.last(name), measurements, metadata})
          end,
          nil
        )

      on_exit(fn -> :telemetry.detach(handler) end)
      runtime = Module.concat(f.namespace, :Runtime)
      Application.put_env(:ash_hooks, runtime, :raise)
      event = Cases.event()
      assert {:ok, :accepted} = Cases.publish(f, event)
      assert_receive {:observed, :publish, %{count: 1}, %{outcome: :attempt}}
      assert_receive {:observed, :publish, %{count: 1}, %{outcome: :accepted}}

      assert_receive {:observed, :trigger, %{count: 1},
                      %{outcome: :failed, reason: "trigger_failed"}}

      assert {:ok, :duplicate} = Cases.publish(f, event)
      assert_receive {:observed, :publish, _, %{outcome: :duplicate}}
      assert {:error, :publication_conflict} = Cases.publish(f, %{event | payload: "conflict"})

      assert_receive {:observed, :publish, _,
                      %{outcome: :refused, reason: "publication_conflict"}}

      assert :done = Cases.fanout(f, event.id)
      assert_receive {:observed, :claim, _, %{outcome: :claimed}}
      assert_receive {:observed, :result, _, %{outcome: :done, reason: nil}}
      pending = Cases.event()
      assert {:ok, :accepted} = Cases.publish(f, pending)
      Cases.set(f, pending.id, dispatch_route: "removed")
      assert {:pending, :unresolved_route} = Cases.fanout(f, pending.id)
      assert_receive {:observed, :result, _, %{outcome: :pending, reason: "unresolved_route"}}
      assert :busy = Cases.fanout(f, pending.id)
      assert_receive {:observed, :claim, _, %{outcome: :busy}}

      Cases.set(f, pending.id,
        format_version: 99,
        next_attempt_at: DateTime.add(DateTime.utc_now(), -1)
      )

      assert :failed = Cases.fanout(f, pending.id)

      assert_receive {:observed, :result, _,
                      %{outcome: :failed, reason: "unsupported_publication_format"}}

      assert {:ok, _} = AshHooks.rearm(f.outbox, pending.id, tenant: "tenant-a")
      assert_receive {:observed, :rearm, _, %{outcome: :pending}}
      assert {:ok, _} = AshHooks.fanout_pending(f.outbox, 10, tenant: "tenant-a")
      assert_receive {:observed, :sweep, _, %{outcome: :complete}}

      assert {:error, :invalid_outbox_query} =
               AshHooks.fanout_pending(f.outbox, 0, tenant: "tenant-a")

      assert_receive {:observed, :sweep, _, %{outcome: :error, reason: "invalid_outbox_query"}}
      # The dedicated blocked-runner case asserts :stale and the absence of result telemetry.
      observed = Cases.observed([])

      for {_name, measurements, metadata} <- observed do
        assert measurements == %{count: 1}
        assert Enum.sort(Map.keys(metadata)) == [:event_uuid, :outcome, :reason]
      end
    end

    test "A13 readable invalid content parks immediately and missing declarations retry", f do
      for values <- [
            [version: 0],
            [payload: ""],
            [metadata: %{"number" => 9_223_372_036_854_775_808}]
          ] do
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        Cases.set(f, event.id, values)
        assert :failed = Cases.fanout(f, event.id)
        row = Cases.publication(f, event.id)
        assert row.attempts == 1
        assert row.last_error == "invalid_publication_content"
      end

      event = Cases.event()
      assert {:ok, :accepted} = Cases.publish(f, event)
      Cases.set(f, event.id, dispatch_source: "removed")
      assert {:pending, :unknown_declaration} = Cases.fanout(f, event.id)
      assert Cases.publication(f, event.id).last_error == "unknown_declaration"
    end

    test "A13 raised and thrown subscription preparations release their claim for retry", f do
      on_exit(fn -> Application.delete_env(:ash_hooks, :outbox_read_failure) end)

      for failure <- [:raise, :throw] do
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        Application.put_env(:ash_hooks, :outbox_read_failure, failure)
        assert {:pending, :fanout_crashed} = Cases.fanout(f, event.id)
        row = Cases.publication(f, event.id)
        assert row.state == :pending
        assert row.last_error == "fanout_crashed"
        assert is_nil(row.claim_token)
        Application.delete_env(:ash_hooks, :outbox_read_failure)
        Cases.expire(f, event)
        assert :done = Cases.fanout(f, event.id)
      end
    end

    test "A13 bounded sweeps isolate poison, park, list and rearm", f do
      poison = Cases.event("a-poison")
      good = Cases.event("b-good")
      for event <- [poison, good], do: assert({:ok, :accepted} = Cases.publish(f, event))
      Cases.set(f, poison.id, format_version: 99)

      assert {:ok, %{failed: 1, done: 1, errors: []}} =
               AshHooks.fanout_pending(f.outbox, 2, tenant: "tenant-a")

      assert {:ok, [%{state: :failed}]} =
               AshHooks.OutboundOutbox.list(f.outbox, tenant: "tenant-a", state: :failed)

      assert :failed = Cases.fanout(f, poison.id)

      assert {:ok, %{state: :pending, attempts: 0, failed_at: nil}} =
               AshHooks.rearm(f.outbox, poison.id, tenant: "tenant-a")

      assert {:error, :publication_not_failed} =
               AshHooks.rearm(f.outbox, poison.id, tenant: "tenant-a")

      assert {:error, :publication_missing} =
               AshHooks.rearm(f.outbox, "missing", tenant: "tenant-a")

      assert :missing = Cases.fanout(f, "missing")

      assert {:error, :invalid_outbox_query} =
               AshHooks.OutboundOutbox.list(f.outbox, tenant: "tenant-a", batch_size: 0)

      Cases.set(f, poison.id, format_version: 1, dispatch_route: "removed")

      for attempt <- 1..3 do
        Cases.set(f, poison.id, next_attempt_at: DateTime.add(DateTime.utc_now(), -1, :second))

        if attempt < 3,
          do: assert({:pending, :unresolved_route} = Cases.fanout(f, poison.id)),
          else: assert(:failed = Cases.fanout(f, poison.id))
      end
    end

    test "A2 and A15 outer actions commit or roll back nested normal, bulk and atomic writes",
         f do
      for kind <- [:normal, :bulk, :atomic], undo? <- [false, true] do
        target =
          if kind == :atomic do
            Ash.create!(f.emitter, %{value: "initial"}, tenant: "tenant-a", authorize?: false)
          end

        before_publications = length(Cases.rows(f, :outbox))
        before_records = length(Cases.rows(f, :emitter))

        result =
          Ash.create(
            f.emitter,
            %{value: "outer", inner_kind: kind, inner_id: target && target.id, undo: undo?},
            action: :outer,
            tenant: "tenant-a",
            authorize?: false
          )

        if undo? do
          assert {:error, _} = result
          assert length(Cases.rows(f, :outbox)) == before_publications
          assert length(Cases.rows(f, :emitter)) == before_records

          if target do
            assert Enum.find(Cases.rows(f, :emitter), &(&1.id == target.id)).value == "initial"
          end
        else
          assert {:ok, %{value: "outer"}} = result
          publications = if kind == :bulk, do: 2, else: 1
          records = %{normal: 2, bulk: 3, atomic: 1}[kind]
          assert length(Cases.rows(f, :outbox)) == before_publications + publications
          assert length(Cases.rows(f, :emitter)) == before_records + records
        end
      end
    end

    test "A15 normal, bulk and atomic actions publish without changing their results", f do
      record =
        Ash.create!(f.emitter, %{value: "created"}, authorize?: false, tenant: "tenant-a")

      assert record.value == "created"
      assert [%{payload: "created"}] = Cases.rows(f, :outbox)
      # Stable IDs intentionally conflict on an update, rolling the action back.
      assert {:error, _} =
               Ash.update(record, %{value: "updated"}, authorize?: false, tenant: "tenant-a")

      assert Enum.find(Cases.rows(f, :emitter), &(&1.id == record.id)).value ==
               "created"

      result =
        Ash.bulk_create([%{value: "one"}, %{value: "two"}], f.emitter, :create,
          authorize?: false,
          tenant: "tenant-a",
          return_records?: true,
          return_errors?: true,
          notify?: false
        )

      assert result.status == :success
      assert length(result.records) == 2
      assert length(Cases.rows(f, :outbox)) == 3
    end
  end
end
