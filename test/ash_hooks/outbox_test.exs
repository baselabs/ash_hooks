Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.OutboxAcceptance do
  @moduledoc false
  import ExUnit.Assertions

  def setup(namespace) do
    sqlite? = namespace == AshHooks.OutboxFixtures.SQLite
    repo = if sqlite?, do: AshHooks.OutboxFixtures.SQLiteRepo, else: AshHooks.TestPostgres.Repo
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

    Enum.each(resources, fn {_name, resource} ->
      table = table(resource)

      fields =
        Enum.map_join(Ash.Resource.Info.attributes(resource), ", ", fn attr ->
          type = if not sqlite? and resource == resources.outbox and attr.name == :metadata,
            do: "JSON",
            else: sql_type(Ash.Type.storage_type(attr.type, attr.constraints), sqlite?)
          "\"#{attr.name}\" #{type}" <> if(attr.primary_key?, do: " PRIMARY KEY", else: "")
        end)

      repo.query!("CREATE TABLE #{table} (#{fields})")
    end)

    repo.query!(
      "CREATE UNIQUE INDEX #{table(resources.outbox)}_unique_publication_index ON #{table(resources.outbox)} (org_id, event_uuid)"
    )

    repo.query!(
      "CREATE UNIQUE INDEX #{table(resources.delivery)}_unique_delivery_index ON #{table(resources.delivery)} (org_id, endpoint_id, event_uuid)"
    )

    ExUnit.Callbacks.on_exit(fn ->
      Enum.each(resources, fn {_name, resource} ->
        repo.query!("DROP TABLE #{table(resource)}")
      end)

      Application.delete_env(:ash_hooks, Module.concat(namespace, :Runtime))

      if sqlite? do
        Supervisor.stop(Process.whereis(repo))
        Enum.each(["", "-shm", "-wal"], &File.rm(database <> &1))
      end
    end)

    Map.merge(resources, %{repo: repo, namespace: namespace, sqlite?: sqlite?})
  end

  def clean(fixture) do
    for key <- [:outbox, :delivery, :subscription, :endpoint, :emitter] do
      fixture.repo.query!("DELETE FROM #{table(fixture[key])}")
    end

    Application.delete_env(:ash_hooks, Module.concat(fixture.namespace, :Runtime))
    :ok
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

  def rows(f, resource, tenant \\ "tenant-a"),
    do: Ash.read!(f[resource], authorize?: false, tenant: tenant)

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
      Enum.map(values, fn {_, value} ->
        case value do
          %DateTime{} ->
            if f.sqlite?, do: DateTime.to_iso8601(value), else: DateTime.to_naive(value)

          other ->
            other
        end
      end) ++ [id]

    fields =
      values
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {{key, _}, n} -> "#{key} = #{parameter(f, n)}" end)

    f.repo.query!(
      "UPDATE #{table(f.outbox)} SET #{fields} WHERE event_uuid = #{parameter(f, length(args))}",
      args
    )
  end

  defp parameter(%{sqlite?: true}, _), do: "?"
  defp parameter(_, n), do: "$#{n}"

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

  defmacro __using__(opts) do
    namespace = Keyword.fetch!(opts, :namespace)

    quote do
      use ExUnit.Case, async: false
      require Ash.Query
      alias AshHooks.OutboxAcceptance, as: Cases
      @namespace unquote(namespace)
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
                 f.repo.transaction(fn ->
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

      test "A2 nested commits and rollbacks do not leak publications", f do
        event = Cases.event()

        assert {:error, :undo} =
                 f.repo.transaction(fn ->
                   assert {:ok, :accepted} = Cases.publish(f, event)
                   f.repo.rollback(:undo)
                 end)

        assert [] = Cases.rows(f, :outbox)

        assert {:ok, :ok} =
                 Ash.transact(f.outbox, fn ->
                   assert {:ok, :ok} =
                            Ash.transact(f.outbox, fn ->
                              assert {:ok, :accepted} = Cases.publish(f, event)
                              :ok
                            end)

                   :ok
                 end)

        assert [_] = Cases.rows(f, :outbox)

        assert {:error, :publication_repository_mismatch} =
                 Cases.publish(f, Cases.event(), dynamic_repo: self())

        assert {:error, :inside_transaction} =
                 f.repo.transaction(fn -> Cases.fanout(f, event.id) end) |> elem(1)
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

      test "A6 tenant, route and content ownership remain distinct", f do
        event = Cases.event()

        results =
          1..2
          |> Task.async_stream(fn _ -> Cases.publish(f, event) end, max_concurrency: 2)
          |> Enum.map(fn {:ok, result} -> result end)

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

      test "A8 pins resolve against the stored publication version", f do
        endpoints = for pin <- [nil, 1, 2], do: Cases.endpoint(f, pinned_payload_version: pin)
        event = Cases.event()
        assert {:ok, :accepted} = Cases.publish(f, event)
        Cases.set(f, event.id, version: 1)
        assert :done = Cases.fanout(f, event.id)
        rows = Cases.rows(f, :delivery)

        for {endpoint, expected} <- Enum.zip(endpoints, ["body", "body", "v2:body"]) do
          assert Enum.find(rows, &(&1.endpoint_id == endpoint.id)).payload == expected
        end
      end

      test "A9 metadata boundaries refuse before SQL and accepted values round trip exactly", f do
        invalid = [
          %{key: true},
          %{"key" => :value},
          %{"key" => self()},
          %{"key" => {1, 2}},
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
            1.7976931348623157e308
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

      test "A11 notifications are after commit and trigger failures cannot fail publish", f do
        runtime = Module.concat(f.namespace, :Runtime)
        Application.put_env(:ash_hooks, runtime, self())

        for mode <- [:ignore, :warn, :raise] do
          previous = Application.get_env(:ash, :missed_notifications)
          Application.put_env(:ash, :missed_notifications, mode)

          try do
            event = Cases.event()

            assert {:ok, :ok} =
                     f.repo.transaction(fn ->
                       assert {:ok, :accepted} = Cases.publish(f, event)
                       refute_receive {:triggered, _, _}
                       :ok
                     end)

            refute_receive {:triggered, _, _}
            assert :done = Cases.fanout(f, event.id)
          after
            if is_nil(previous),
              do: Application.delete_env(:ash, :missed_notifications),
              else: Application.put_env(:ash, :missed_notifications, previous)
          end
        end

        event = Cases.event()

        assert {:ok, :ok} =
                 Ash.transact(f.outbox, fn ->
                   assert {:ok, :accepted} = Cases.publish(f, event)
                   refute_receive {:triggered, _, _}
                   :ok
                 end)

        assert_receive {:triggered, id, "tenant-a"}
        assert id == event.id
        assert {:ok, :accepted} = Cases.publish(f, Cases.event(), return_notifications?: true)
        refute_receive {:triggered, _, _}

        for failure <- [:raise, :exit, :throw, :error] do
          Application.put_env(:ash_hooks, runtime, failure)
          assert {:ok, :accepted} = Cases.publish(f, Cases.event())
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

      test "A15 normal, bulk and atomic actions publish without changing their results", f do
        record =
          Ash.create!(f.emitter, %{value: "created"}, authorize?: false, tenant: "tenant-a")

        assert record.value == "created"
        assert [%{payload: "created"}] = Cases.rows(f, :outbox)
        # Stable IDs intentionally conflict on an update, rolling the action back.
        assert {:error, _} =
                 Ash.update(record, %{value: "updated"}, authorize?: false, tenant: "tenant-a")

        assert Ash.get!(f.emitter, record.id, authorize?: false, tenant: "tenant-a").value ==
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
end

defmodule AshHooks.OutboxSQLiteTest do
  use AshHooks.OutboxAcceptance, namespace: AshHooks.OutboxFixtures.SQLite
end

defmodule AshHooks.OutboxPostgresTest do
  use AshHooks.OutboxAcceptance, namespace: AshHooks.OutboxFixtures.Postgres
  @moduletag :postgres
end
