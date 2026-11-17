Code.require_file("outbox_process.exs", __DIR__)
Code.require_file("outbox_resources.exs", __DIR__)

for {namespace, layer, repo, prefix} <- [
      {AshHooks.OutboxFixtures.SQLite, AshSqlite.DataLayer, AshHooks.OutboxFixtures.SQLiteRepo,
       "outbox_sqlite"},
      {AshHooks.OutboxFixtures.Postgres, AshPostgres.DataLayer,
       AshHooks.OutboxFixtures.Postgres.Repo, "outbox_postgres"}
    ] do
  domain = Module.concat(namespace, :NotificationDomain)
  outbox = Module.concat(namespace, :HostOutbox)
  publisher = Module.concat(namespace, :HostPublisher)
  control = Module.concat(namespace, :NotificationControl)
  emitter = Module.concat(namespace, :Emitter)
  runtime = Module.concat(namespace, :Runtime)
  path = if layer == AshSqlite.DataLayer, do: :sqlite, else: :postgres

  configuration = fn table ->
    {path, [],
     [[do: quote do
       table(unquote(table))
       repo(unquote(repo))
     end]]}
  end

  Code.eval_quoted(
    quote do
      defmodule unquote(outbox) do
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: unquote(layer),
          extensions: [AshHooks.OutboundOutbox],
          notifiers: [AshHooks.OutboxFixtures.HostNotifier]

        unquote(configuration.(prefix <> "_publications"))

        attributes do
          attribute :org_id, :string, allow_nil?: false
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        actions do
          defaults [:read]
        end

        changes do
          change AshHooks.OutboxFixtures.HostNotifications, on: [:create]
        end

        outbox do
          declarations [{unquote(emitter), :changed}]
          delivery_routes default: nil
          trigger {unquote(runtime), :trigger}
          deduplication_horizon_seconds 3600
        end
      end

      defmodule unquote(control) do
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: unquote(layer),
          notifiers: [AshHooks.OutboxFixtures.HostNotifier]

        unquote(configuration.(prefix <> "_emitters"))

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string, allow_nil?: false
          attribute :value, :string, default: "body", public?: true
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        actions do
          defaults [:read, :create]
        end

        changes do
          change AshHooks.OutboxFixtures.HostNotifications, on: [:create]
        end
      end

      defmodule unquote(publisher) do
        use Ash.Resource,
          domain: unquote(domain),
          data_layer: unquote(layer),
          extensions: [AshHooks]

        unquote(configuration.(prefix <> "_emitters"))

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string, allow_nil?: false
          attribute :value, :string, default: "body", public?: true
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        actions do
          defaults [:read]

          create :create do
            primary? true

            change {AshHooks.Changes.Publish,
                    outbox: unquote(outbox),
                    declaration: {unquote(emitter), :changed},
                    build: {unquote(runtime), :build}}
          end
        end
      end

      defmodule unquote(domain) do
        use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

        resources do
          resource unquote(outbox)
          resource unquote(control)
          resource unquote(publisher)
        end
      end
    end
  )
end

for {test_module, namespace} <- [
      {AshHooks.OutboxNotificationsSQLiteTest, AshHooks.OutboxFixtures.SQLite},
      {AshHooks.OutboxNotificationsPostgresTest, AshHooks.OutboxFixtures.Postgres}
    ] do
  defmodule test_module do
    use ExUnit.Case, async: false
    import ExUnit.CaptureLog
    alias AshHooks.OutboxAcceptance, as: Cases
    @namespace namespace
    if @namespace == AshHooks.OutboxFixtures.Postgres, do: @moduletag(:postgres)

    setup_all do
      {:ok, Cases.setup(@namespace)}
    end

    setup f do
      Cases.clean(f)
      previous = Application.get_env(:ash, :missed_notifications)
      Application.put_env(:ash_hooks, :outbox_host_observer, self())
      Application.put_env(:ash_hooks, Module.concat(@namespace, :Runtime), self())

      on_exit(fn ->
        Application.delete_env(:ash_hooks, :outbox_host_observer)

        if is_nil(previous),
          do: Application.delete_env(:ash, :missed_notifications),
          else: Application.put_env(:ash, :missed_notifications, previous)
      end)
    end

    for setting <- [:ignore, :warn, :raise],
        mode <- [:none, :ash, :raw, :ash_in_raw],
        returned? <- [false, true],
        operation <- [:publish, :change] do
      @tag setting: setting, mode: mode, operation: operation, returned?: returned?
      test "A11 #{operation} preserves host notifications in #{mode}, #{setting}, returned #{returned?}", f do
        Application.put_env(:ash, :missed_notifications, f.setting)
        control = observe(f, :control)
        actual = observe(f, f.operation)
        assert actual == control
      end
    end

    test "A11 package trigger failures never reach a caller after commit", f do
      for operation <- [:publish, :change], failure <- [:raise, :exit, :throw, :error] do
        Application.put_env(:ash_hooks, Module.concat(@namespace, :Runtime), failure)
        assert :success = invoke(f, operation, [])
        assert length(host_notifications([])) == 2
      end
    end

    defp observe(f, operation) do
      owner = self()

      log = capture_log(fn ->
        result = safely(fn -> in_mode(f, operation) end)
        hosts = host_notifications([])
        hints = hints([])
        expected_hints =
          if operation != :control and result == :success and
               (f.returned? or f.mode in [:none, :ash]), do: 1, else: 0

        assert length(hints) == expected_hints
        send(owner, {:observation, result, Enum.sort(hosts)})
      end)

      assert_receive {:observation, result, hosts}
      {result, hosts, Regex.scan(~r/Missed (\d+) notifications/, log, capture: :all_but_first)}
    end

    defp in_mode(f, operation) do
      opts = if f.returned?, do: [return_notifications?: true], else: []

      callback = fn ->
        result = invoke(f, operation, opts)
        if f.mode != :none, do: assert(hints([]) == [])
        result
      end

      case run_mode(f, callback) do
        {:returned, notifications} ->
          assert [] = Ash.Notifier.notify(notifications)
          :success

        result -> result
      end
    end

    defp run_mode(%{mode: :none}, callback), do: callback.()
    defp run_mode(%{mode: :ash} = f, callback),
      do: Ash.transact(f.outbox, callback, tenant: "tenant-a") |> unwrap()
    defp run_mode(%{mode: :raw} = f, callback),
      do: Cases.transaction(f, callback) |> unwrap()
    defp run_mode(%{mode: :ash_in_raw} = f, callback) do
      Cases.transaction(f, fn ->
        Ash.transact(f.outbox, callback, tenant: "tenant-a")
      end)
      |> unwrap()
    end

    defp unwrap({:ok, result}), do: unwrap(result)
    defp unwrap(result), do: result

    defp invoke(f, :publish, opts) do
      outbox = Module.concat(@namespace, :HostOutbox)

      AshHooks.publish(outbox, {f.emitter, :changed}, Cases.event(),
        Keyword.merge([tenant: "tenant-a"], opts)
      )
      |> normalize()
    end

    defp invoke(_f, operation, opts) do
      resource =
        Module.concat(@namespace, if(operation == :control, do: :NotificationControl, else: :HostPublisher))

      Ash.create(resource, %{}, Keyword.merge([authorize?: false, tenant: "tenant-a"], opts))
      |> normalize()
    end

    defp normalize({:ok, _row, notifications}), do: {:returned, notifications}
    defp normalize({:ok, :success}), do: :success
    defp normalize({:ok, {:ok, result}}), do: normalize({:ok, result})
    defp normalize({:ok, _row}), do: :success
    defp normalize({:error, error}), do: {:error, missed?(error)}

    defp safely(operation) do
      operation.()
    rescue
      error -> {:raised, missed?(error)}
    end

    defp missed?(error), do: String.contains?(inspect(error), "Missed ")

    defp host_notifications(acc) do
      receive do
        {:host_notification, notification} ->
          host_notifications([Map.get(notification.metadata, :host, false) | acc])
      after
        0 -> acc
      end
    end

    defp hints(acc) do
      receive do
        {:triggered, id, tenant} -> hints([{id, tenant} | acc])
      after
        0 -> acc
      end
    end
  end
end
