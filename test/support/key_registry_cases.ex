defmodule AshHooks.Test.KeyRegistryCases do
  @moduledoc false
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias Ash.Resource.Info
  alias AshHooks.KeyRegistry
  alias AshHooks.KeyRegistry.{Storage, Transitions}
  alias AshHooks.Test.{RegistryCustodian, RegistryOtherRepo}
  alias Spark.Dsl.Extension
  require Spark.Test

  @clock ~U[2026-11-14 12:00:00.000000Z]
  @kind {:standard_webhooks, :v1}
  @material :binary.copy(<<42>>, 32)

  def cases do
    [
      :schema,
      :crash_recovery,
      :outer_transaction_refused,
      :late_store_tombstone,
      :attach_timeout_race,
      :owner_deletion,
      :owner_replacement,
      :rollback_retirement,
      :destroy_results,
      :unavailable_backoff,
      :rearm_generation,
      :canonical_disposal_tenant,
      :lifecycle_retirement,
      :byte_and_mixed_slots,
      :lost_attach_cleanup,
      :pruning,
      :configuration_guards,
      :dynamic_repo_guard,
      :dynamic_repo_instances,
      :custodian_delegation,
      :attachment_guards,
      :storage_configuration,
      :unscoped_disposal,
      :primary_identity,
      :scheduled_destruction
    ]
  end

  def setup_all(test_module, layer, repo, prefix) do
    if layer == AshSqlite.DataLayer do
      Application.put_env(
        :ash_hooks,
        repo,
        Keyword.put(Application.fetch_env!(:ash_hooks, AshHooks.Test.Repo), :log, false)
      )

      {:ok, pid} = repo.start_link()
      Process.unlink(pid)
    end

    registry = Module.concat(test_module, Registry)
    endpoint = Module.concat(test_module, Endpoint)
    domain = Module.concat(test_module, Domain)
    storage = if layer == AshPostgres.DataLayer, do: :postgres, else: :sqlite

    custodian =
      if storage == :postgres, do: AshHooks.TestPostgres.Custodian, else: AshHooks.Test.Custodian

    ctx = %{
      registry: registry,
      endpoint: endpoint,
      domain: domain,
      layer: layer,
      repo: repo,
      storage: storage,
      custodian: custodian,
      registry_table: prefix <> "_keys",
      endpoint_table: prefix <> "_endpoints"
    }

    Code.compile_quoted(
      quote do
        defmodule unquote(domain) do
          use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

          resources do
            allow_unregistered? true
          end
        end
      end
    )

    compile_registry(ctx)
    compile_endpoint(ctx, endpoint, [])

    create_tables(ctx)
    custodian.setup_store!()

    on_exit(fn ->
      custodian.drop_store!()
      repo.query!("DROP TABLE #{ctx.endpoint_table}", [], log: false)
      repo.query!("DROP TABLE #{ctx.registry_table}", [], log: false)
      purge([registry, endpoint, domain])

      if layer == AshSqlite.DataLayer do
        Supervisor.stop(repo)
        Application.delete_env(:ash_hooks, repo)
      end
    end)

    ctx
  end

  def clean(ctx) do
    ctx.repo.query!("DELETE FROM #{ctx.endpoint_table}", [], log: false)
    ctx.repo.query!("DELETE FROM #{ctx.registry_table}", [], log: false)
    Process.put(:registry_custodian, ctx.custodian)
    Process.delete(:registry_destroy_answers)
    :ok
  end

  def schema(ctx) do
    if ctx.storage == :sqlite, do: assert(ctx.repo.min_sqlite_version().major == 3)
    assert Info.primary_key(ctx.registry) == [:ref]

    expected =
      ~w(ref kind owner_resource owner_key state custody_tenant issued_at destroy_after attempts next_attempt_at destroy_generation last_error inserted_at updated_at tenant_id)a

    assert MapSet.new(Enum.map(Info.attributes(ctx.registry), & &1.name)) == MapSet.new(expected)
    assert Extension.get_opt(ctx.registry, [:key_registry], :issue_timeout) == 900
    {:ok, issued} = issue(ctx)
    assert issued.state == :issued
    assert issued.destroy_generation == 0
    assert issued.attempts == 0
    assert issued.kind == @kind
    assert issued.custody_tenant == "17"
    assert "ahk_" <> uuid = issued.ref
    assert {:ok, ^uuid} = Ash.Type.cast_input(:uuid_v7, uuid)
    assert is_nil(issued.owner_key)
    assert is_nil(issued.last_error)
    assert {:ok, again} = issue(ctx)
    refute again.ref == issued.ref
    assert {:ok, []} = KeyRegistry.pending(ctx.registry, tenant: 18)
  end

  def crash_recovery(ctx) do
    for point <- [:before_store, :after_store, :rolled_back_attach, :after_attach] do
      {:ok, row} = issue(ctx)

      if point != :before_store,
        do: assert(:ok == ctx.custodian.store(row.ref, @material, "17", @kind))

      simulate_crash(ctx, row, point)

      assert {:ok, _} = sweep(ctx, now: DateTime.add(@clock, 901))
      assert stored(ctx, row).state == if(point == :after_attach, do: :attached, else: :destroyed)
    end
  end

  defp simulate_crash(ctx, row, :rolled_back_attach) do
    assert {:error, :crash} =
             transaction(ctx, fn ->
               owner = endpoint!(ctx, secret_ref: row.ref, secret_kind: @kind)
               assert {:ok, _} = Transitions.attach(ctx.endpoint, row.ref, tenant: 17)
               assert owner.secret_ref == row.ref
               Ash.DataLayer.rollback(ctx.endpoint, :crash)
             end)
  end

  defp simulate_crash(ctx, row, :after_attach), do: attach!(ctx, row)
  defp simulate_crash(_ctx, _row, _point), do: :ok

  def outer_transaction_refused(ctx) do
    assert {:ok, :ok} =
             transaction(ctx, fn ->
               assert {:error, :inside_transaction} = issue(ctx)
               assert {:error, :inside_transaction} = sweep(ctx)
               :ok
             end)

    assert Ash.read!(ctx.registry, authorize?: false, tenant: 17) == []
  end

  def late_store_tombstone(ctx) do
    {:ok, row} = issue(ctx)
    assert {:ok, _} = sweep(ctx, now: DateTime.add(@clock, 901))
    assert stored(ctx, row).state == :destroyed
    assert {:error, :ref_destroyed} = ctx.custodian.store(row.ref, @material, "17", @kind)
  end

  def attach_timeout_race(ctx) do
    {:ok, row} = issue(ctx)
    parent = self()

    attach =
      Task.async(fn ->
        send(parent, {:ready, self()})

        receive do
          :go ->
            transaction(ctx, fn ->
              endpoint!(ctx, secret_ref: row.ref, secret_kind: @kind)
              Transitions.attach(ctx.endpoint, row.ref, tenant: 17)
            end)
        end
      end)

    timeout =
      Task.async(fn ->
        Process.put(:registry_custodian, ctx.custodian)
        send(parent, {:ready, self()})

        receive do
          :go -> sweep(ctx, now: DateTime.add(@clock, 901))
        end
      end)

    assert_receive {:ready, _}, 5_000
    assert_receive {:ready, _}, 5_000
    send(attach.pid, :go)
    send(timeout.pid, :go)
    result = Task.await(attach)
    assert {:ok, _} = Task.await(timeout)

    attached? = match?({:ok, {:ok, _}}, result)
    assert attached? or result == {:error, :key_issue_expired}
    assert stored(ctx, row).state in [:attached, :destroyed]
    assert stored(ctx, row).state == :attached == attached?
  end

  def owner_deletion(ctx) do
    for mode <- [:action, :bulk, :sql] do
      {row, owner} = attached!(ctx)

      case mode do
        :action ->
          Ash.destroy!(owner, authorize?: false, tenant: 17)

        :bulk ->
          result =
            Ash.bulk_destroy([owner], :destroy, %{},
              authorize?: false,
              tenant: 17,
              return_errors?: true
            )

          assert result.status == :success

        :sql ->
          ctx.repo.query!("DELETE FROM #{ctx.endpoint_table} WHERE id = $1", [
            native_id(ctx, owner.id)
          ])
      end

      assert {:ok, _} = sweep(ctx)
      assert stored(ctx, row).state == :destroyed
      assert {:error, :unknown_ref} = ctx.custodian.sign(row.ref, "17", @kind, "message")
    end
  end

  def owner_replacement(ctx) do
    {row, owner} = attached!(ctx)
    update!(owner, %{secret_ref: "host-replacement", secret_kind: nil})
    assert {:ok, _} = sweep(ctx)
    assert stored(ctx, row).state == :destroyed
  end

  def rollback_retirement(ctx) do
    for operation <- [:expire, :sweep, :roll, :delete] do
      {row, owner} = attached!(ctx, :previous)

      assert {:error, :rollback} =
               transaction(ctx, fn ->
                 perform_retirement(ctx, owner, operation, tenant: 17, now: @clock)

                 assert {:ok, _} =
                          AshHooks.Endpoint.expire_previous_secrets(ctx.endpoint,
                            tenant: 17,
                            now: @clock
                          )

                 assert {:error, :inside_transaction} = sweep(ctx)
                 assert {:ok, _} = ctx.custodian.sign(row.ref, "17", @kind, "message")
                 Ash.DataLayer.rollback(ctx.endpoint, :rollback)
               end)

      assert stored(ctx, row).state == :attached

      assert Ash.get!(ctx.endpoint, owner.id, authorize?: false, tenant: 17).previous_secret_ref ==
               row.ref
    end
  end

  def destroy_results(ctx) do
    handler = "registry-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:ash_hooks, :key_registry, :destroy_failed],
        &__MODULE__.destroy_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    for {answer, state, classification} <- [
          {:ok, :destroyed, nil},
          {{:error, :unavailable}, :retired, "key_unavailable"},
          {{:error, :tenant_mismatch}, :destroy_failed, "tenant_mismatch"},
          {{:unexpected, "private backend detail"}, :destroy_failed, "unclassified"}
        ] do
      {:ok, row} = issue(ctx)

      if answer == {:error, :tenant_mismatch},
        do: assert(:ok == ctx.custodian.store(row.ref, @material, "18", @kind))

      assert :ok = Transitions.cleanup(ctx.endpoint, row.ref, tenant: 17, now: @clock)

      Process.put(
        :registry_destroy_answers,
        if(answer == {:error, :tenant_mismatch}, do: [], else: [answer])
      )

      assert {:ok, counts} = sweep(ctx)

      assert counts.destroy_failed ==
               length(elem(KeyRegistry.pending(ctx.registry, tenant: 17), 1))

      result = stored(ctx, row)
      assert result.state == state
      assert result.last_error == classification
      refute inspect(result) =~ "private backend detail"

      if state == :destroy_failed do
        assert_receive {:destroy_event, %{count: 1}, metadata}
        assert metadata.ref == row.ref
        assert metadata.reason in [:tenant_mismatch, :unclassified]
        refute inspect(metadata) =~ "private backend detail"
      end
    end
  end

  def unavailable_backoff(ctx) do
    {:ok, row} = issue(ctx)
    assert :ok = Transitions.cleanup(ctx.endpoint, row.ref, tenant: 17, now: @clock)
    Process.put(:registry_destroy_answers, [{:error, :unavailable}])
    assert {:ok, _} = sweep(ctx)
    first = stored(ctx, row)
    assert first.attempts == 1
    assert DateTime.compare(first.next_attempt_at, @clock) == :gt
    assert {:ok, _} = sweep(ctx)
    assert stored(ctx, row).attempts == 1
    Process.put(:registry_destroy_answers, [{:error, :unavailable}])
    assert {:ok, _} = sweep(ctx, now: first.next_attempt_at)
    second = stored(ctx, row)
    assert second.attempts == 2

    assert DateTime.diff(second.next_attempt_at, first.next_attempt_at) >
             DateTime.diff(first.next_attempt_at, @clock)

    {last, previous} =
      Enum.reduce(1..13, {second, first}, fn _, {current, _previous} ->
        Process.put(:registry_destroy_answers, [{:error, :unavailable}])
        assert {:ok, _} = sweep(ctx, now: current.next_attempt_at)
        updated = stored(ctx, row)
        assert DateTime.diff(updated.next_attempt_at, current.next_attempt_at) <= 3_600
        {updated, current}
      end)

    assert DateTime.diff(last.next_attempt_at, previous.next_attempt_at) == 3_600
    assert {:ok, _} = sweep(ctx, now: last.next_attempt_at)
    assert stored(ctx, row).state == :destroyed
    assert {:error, :not_destroy_failed} = KeyRegistry.rearm(ctx.registry, row.ref, tenant: 17)
  end

  def rearm_generation(ctx) do
    {:ok, row} = issue(ctx)
    assert :ok = Transitions.cleanup(ctx.endpoint, row.ref, tenant: 17, now: @clock)
    Process.put(:registry_destroy_answers, [{:error, :unavailable}])
    assert {:ok, _} = sweep(ctx)
    assert stored(ctx, row).attempts == 1
    eligible = stored(ctx, row).next_attempt_at
    parent = self()

    old =
      Task.async(fn ->
        Process.put(:registry_custodian, ctx.custodian)

        Process.put(:registry_destroy_answers, [
          {:delay, parent, {:error, :unexpected_backend_answer}}
        ])

        sweep(ctx, now: eligible)
      end)

    assert_receive {:destroy_waiting, delayed, ref, "17"}, 5_000
    assert ref == row.ref
    Process.put(:registry_destroy_answers, [{:error, :unexpected_backend_answer}])
    assert {:ok, counts} = sweep(ctx, now: eligible)
    assert counts.destroy_failed == 1
    assert stored(ctx, row).state == :destroy_failed
    assert {:ok, [pending]} = KeyRegistry.pending(ctx.registry, tenant: 17)
    assert pending.ref == row.ref
    assert {:ok, _} = sweep(ctx)
    assert stored(ctx, row).state == :destroy_failed
    assert {:ok, rearmed} = KeyRegistry.rearm(ctx.registry, row.ref, tenant: 17)
    assert rearmed.destroy_generation == 1
    assert rearmed.attempts == 0
    assert is_nil(rearmed.next_attempt_at)
    send(delayed, :finish_destroy)
    assert {:ok, _} = Task.await(old)
    assert stored(ctx, row).state == :retired
    assert stored(ctx, row).destroy_generation == 1
    assert {:ok, _} = sweep(ctx)
    assert stored(ctx, row).state == :destroyed
  end

  def canonical_disposal_tenant(ctx) do
    {:ok, row} = issue(ctx, tenant: "017")
    assert row.custody_tenant == "17"
    assert :ok = ctx.custodian.store(row.ref, @material, "17", @kind)
    owner = attach!(ctx, row)
    Ash.destroy!(owner, authorize?: false, tenant: "17")
    assert {:ok, _} = sweep(ctx, tenant: "017")
    assert stored(ctx, row).state == :destroyed
    assert {:error, :ref_destroyed} = ctx.custodian.store(row.ref, @material, "17", @kind)
  end

  def lifecycle_retirement(ctx) do
    for slot <- [:standard, :legacy], operation <- [:expire, :sweep, :roll] do
      kind = if slot == :standard, do: @kind, else: {:legacy_hmac, :sha256}
      fields = AshHooks.KeyLifecycle.fields(slot)
      {row, owner} = attached!(ctx, {:previous, slot, kind})

      assert {:ok, :ok} =
               transaction(ctx, fn ->
                 perform_retirement(ctx, owner, operation, tenant: 17, slot: slot, now: @clock)

                 assert stored(ctx, row).state == :retired
                 assert stored(ctx, row).destroy_after == @clock
                 assert {:ok, _} = ctx.custodian.sign(row.ref, "17", kind, "message")
                 :ok
               end)

      refute Map.get(
               Ash.get!(ctx.endpoint, owner.id, authorize?: false, tenant: 17),
               fields.previous_ref
             ) == row.ref

      assert {:ok, _} = sweep(ctx)
      assert stored(ctx, row).state == :destroyed
    end
  end

  def byte_and_mixed_slots(ctx) do
    check_byte_slots(ctx)
    check_marker_movement(ctx)
    check_mixed_slots(ctx)
  end

  defp check_marker_movement(ctx) do
    for slot <- [:standard, :legacy] do
      kind = if slot == :standard, do: @kind, else: {:legacy_hmac, :sha256}
      fields = AshHooks.KeyLifecycle.fields(slot)
      {row, owner} = attached!(ctx, {:current, slot, kind})

      assert {:ok, rolled} =
               AshHooks.Endpoint.roll_secret(owner,
                 new_secret_ref: "new-host",
                 slot: slot,
                 tenant: 17,
                 now: @clock
               )

      assert Map.get(rolled, fields.previous_ref) == row.ref
      assert Map.get(rolled, fields.previous_kind) == kind
      assert is_nil(Map.get(rolled, fields.kind))
      assert stored(ctx, row).state == :attached

      assert {:ok, _} =
               AshHooks.Endpoint.expire_previous_secret(rolled,
                 slot: slot,
                 tenant: 17,
                 now: @clock
               )

      assert stored(ctx, row).state == :retired
      assert {:ok, _} = sweep(ctx)
      assert stored(ctx, row).state == :destroyed
    end
  end

  defp check_byte_slots(ctx) do
    for operation <- [:expire, :sweep, :roll] do
      owner = endpoint!(ctx, previous_secret_ref: "host-old", previous_secret_retired_at: @clock)

      case operation do
        :expire ->
          assert {:ok, _} =
                   AshHooks.Endpoint.expire_previous_secret(owner, tenant: 17, now: @clock)

        :sweep ->
          assert {:ok, _} =
                   AshHooks.Endpoint.expire_previous_secrets(ctx.endpoint,
                     tenant: 17,
                     now: @clock
                   )

        :roll ->
          assert {:ok, _} =
                   AshHooks.Endpoint.roll_secret(owner,
                     new_secret_ref: "new-host",
                     tenant: 17,
                     now: @clock
                   )
      end

      assert Ash.read!(ctx.registry, authorize?: false, tenant: 17) == []
    end
  end

  defp check_mixed_slots(ctx) do
    for operation <- [:expire, :sweep, :roll] do
      {row, owner} = attached!(ctx)

      owner =
        update!(owner, %{
          previous_secret_ref: "host-bytes",
          previous_secret_kind: nil,
          previous_secret_retired_at: @clock
        })

      case operation do
        :expire ->
          assert {:ok, _} =
                   AshHooks.Endpoint.expire_previous_secret(owner, tenant: 17, now: @clock)

        :sweep ->
          assert {:ok, _} =
                   AshHooks.Endpoint.expire_previous_secrets(ctx.endpoint,
                     tenant: 17,
                     now: @clock
                   )

        :roll ->
          assert {:ok, rolled} =
                   AshHooks.Endpoint.roll_secret(owner,
                     new_secret_ref: "new-host",
                     tenant: 17,
                     now: @clock
                   )

          assert rolled.previous_secret_kind == @kind
          assert is_nil(rolled.secret_kind)
      end

      assert {:ok, _} = sweep(ctx)
      assert stored(ctx, row).state == :attached
    end
  end

  defp perform_retirement(_ctx, owner, :expire, opts) do
    assert {:ok, _} = AshHooks.Endpoint.expire_previous_secret(owner, opts)
  end

  defp perform_retirement(ctx, _owner, :sweep, opts) do
    assert {:ok, _} = AshHooks.Endpoint.expire_previous_secrets(ctx.endpoint, opts)
  end

  defp perform_retirement(_ctx, owner, :roll, opts) do
    assert {:ok, _} =
             AshHooks.Endpoint.roll_secret(
               owner,
               Keyword.put(opts, :new_secret_ref, "new-host-ref")
             )
  end

  defp perform_retirement(_ctx, owner, :delete, opts) do
    assert :ok = Ash.destroy(owner, authorize?: false, tenant: opts[:tenant])
  end

  def lost_attach_cleanup(ctx) do
    {:ok, row} = issue(ctx)
    endpoint!(ctx, secret_ref: row.ref, secret_kind: @kind)
    assert :ok = Transitions.cleanup(ctx.endpoint, row.ref, tenant: 17, now: @clock)

    assert {:error, :key_issue_expired} =
             transaction(ctx, fn ->
               Transitions.attach(ctx.endpoint, row.ref, tenant: 17)
             end)

    assert :ok = Transitions.cleanup(ctx.endpoint, row.ref, tenant: 17, now: @clock)
    assert stored(ctx, row).state == :retired
    assert {:ok, _} = sweep(ctx)
    assert stored(ctx, row).state == :destroyed

    assert {:ok, 1} =
             KeyRegistry.prune(ctx.registry,
               tenant: 17,
               before: DateTime.add(DateTime.utc_now(), 60)
             )

    assert {:error, :key_issue_expired} =
             transaction(ctx, fn ->
               Transitions.attach(ctx.endpoint, row.ref, tenant: 17)
             end)
  end

  def pruning(ctx) do
    {:ok, row} = issue(ctx)
    assert :ok = Transitions.cleanup(ctx.endpoint, row.ref, tenant: 17, now: @clock)
    assert {:ok, _} = sweep(ctx)
    {:ok, pending} = issue(ctx, now: ~U[2000-01-01 00:00:00Z])

    assert {:ok, 0} =
             KeyRegistry.prune(ctx.registry, tenant: 17, before: ~U[2000-01-01 00:00:00Z])

    assert {:ok, 1} =
             KeyRegistry.prune(ctx.registry,
               tenant: 17,
               before: DateTime.add(DateTime.utc_now(), 60)
             )

    assert stored(ctx, pending).state == :issued

    assert Enum.map(Ash.read!(ctx.registry, authorize?: false, tenant: 17), & &1.ref) == [
             pending.ref
           ]
  end

  def configuration_guards(ctx) do
    for opts <- [[key_lifecycle: :off], [key_registry: nil]] do
      errors =
        Spark.Test.dsl_errors do
          compile_endpoint(ctx, unique(ctx, "Invalid"), opts)
        end

      assert [{_, errors}] = errors
      assert Enum.any?(errors, &(Exception.message(&1) =~ "requires"))
    end

    for layer <- [Ash.DataLayer.Ets, Ash.DataLayer.Simple] do
      errors =
        Spark.Test.dsl_errors do
          name = unique(ctx, "InvalidRegistry")

          Code.compile_quoted(
            quote do
              defmodule unquote(name) do
                use Ash.Resource, data_layer: unquote(layer), extensions: [AshHooks.KeyRegistry]
              end
            end
          )
        end

      assert [{_, [%Spark.Error.DslError{} = error]}] = errors
      assert Exception.message(error) =~ "AshPostgres or AshSqlite"
    end

    resource = unique(ctx, "Bytes")
    compile_endpoint(ctx, resource, custodian: nil)

    for name <- [
          :secret_kind,
          :previous_secret_kind,
          :legacy_secret_kind,
          :legacy_previous_secret_kind
        ] do
      assert is_nil(Info.attribute(resource, name))
      assert Info.attribute(ctx.endpoint, name)
    end
  end

  def dynamic_repo_guard(ctx) do
    resource = unique(ctx, "DynamicRepo")
    Process.put(:registry_wrong_repo, ctx.repo)
    compile_endpoint(ctx, resource, repo: &__MODULE__.repo/2)
    Process.put(:registry_wrong_repo, ctx.repo)
    assert {:ok, row} = Transitions.issue(resource, @kind, tenant: 17, now: @clock)

    owner =
      endpoint!(%{ctx | endpoint: resource},
        previous_secret_ref: "host-previous",
        previous_secret_retired_at: @clock
      )

    handler = "registry-repo-switch-#{System.unique_integer([:positive])}"
    event = ctx.repo.config()[:telemetry_prefix] ++ [:query]

    :ok =
      :telemetry.attach(handler, event, &__MODULE__.switch_repo_after_read/4, ctx.endpoint_table)

    on_exit(fn -> :telemetry.detach(handler) end)
    Process.put(:registry_switch_repo, true)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             AshHooks.Endpoint.expire_previous_secrets(resource, tenant: 17, now: @clock)

    assert stored(ctx, row).state == :issued

    Process.put(:registry_wrong_repo, RegistryOtherRepo)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             Transitions.issue(resource, @kind, tenant: 17, now: @clock)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             Transitions.attach(resource, row.ref, tenant: 17)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             Transitions.cleanup(resource, row.ref, tenant: 17)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             Transitions.retire(resource, row.ref, @clock, tenant: 17)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} = sweep(ctx)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             AshHooks.Endpoint.expire_previous_secrets(resource, tenant: 17, now: @clock)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             AshHooks.Endpoint.expire_previous_secret(owner, tenant: 17, now: @clock)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             AshHooks.Endpoint.roll_secret(owner, new_secret_ref: "next", tenant: 17, now: @clock)

    Process.delete(:registry_wrong_repo)
  end

  def dynamic_repo_instances(ctx) do
    original = ctx.repo.get_dynamic_repo()
    {:ok, instance} = ctx.repo.start_link(name: nil)
    Process.unlink(instance)
    on_exit(fn -> Supervisor.stop(instance) end)
    ctx.repo.put_dynamic_repo(instance)
    assert %{rows: [[1]]} = ctx.repo.query!("SELECT 1", [], log: false)
    ctx.repo.put_dynamic_repo(original)

    registry = unique(ctx, "DynamicRegistry")
    endpoint = unique(ctx, "DynamicEndpoint")
    on_exit(fn -> purge([registry, endpoint]) end)

    Process.put(:registry_repo_instances, %{
      registry => {ctx.repo, original},
      endpoint => {ctx.repo, instance}
    })

    configured =
      %{ctx | registry: registry, endpoint: endpoint}
      |> Map.put(:registry_repo, &__MODULE__.instance_repo/2)

    compile_registry(configured)
    compile_endpoint(configured, endpoint, repo: &__MODULE__.instance_repo/2)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             Storage.check(registry, endpoint)

    assert {:error, %AshHooks.Errors.Invalid.KeyKindMismatch{}} =
             Transitions.issue(endpoint, @kind, tenant: 17)

    ctx.repo.put_dynamic_repo(original)
  end

  def instance_repo(resource, _type) do
    case Process.get(:registry_repo_instances, %{})[resource] do
      nil ->
        AshHooks.Test.RegistryRepo

      {repo, instance} ->
        repo.put_dynamic_repo(instance)
        repo
    end
  end

  def switch_repo_after_read(_event, _measurements, metadata, table) do
    if Process.get(:registry_switch_repo, false) and String.starts_with?(metadata.query, "SELECT") and
         String.contains?(metadata.query, table) do
      Process.delete(:registry_switch_repo)
      Process.put(:registry_wrong_repo, AshHooks.Test.BusyRepo)
    end
  end

  def attachment_guards(ctx) do
    {:ok, row} = issue(ctx)
    assert {:error, :key_issue_expired} = Transitions.attach(ctx.endpoint, row.ref, tenant: 17)
    assert stored(ctx, row).state == :issued

    assert {:ok, :ok} =
             transaction(ctx, fn ->
               assert {:error, :inside_transaction} =
                        Transitions.cleanup(ctx.endpoint, row.ref, tenant: 17)

               :ok
             end)

    assert {:error, _} = Transitions.retire(ctx.endpoint, row.ref, "invalid time", tenant: 17)
    assert {:error, :tenant_required} = Transitions.issue(ctx.endpoint, @kind, [])
    assert {:error, :invalid_tenant} = issue(ctx, tenant: "invalid integer")

    invalid =
      ctx.registry
      |> Ash.Changeset.for_create(
        :issue_key,
        %{
          ref: "ahk_" <> Ash.UUIDv7.generate(),
          kind: @kind,
          owner_resource: ctx.endpoint,
          custody_tenant: "18",
          issued_at: @clock
        },
        tenant: 17
      )
      |> Ash.create!(authorize?: false)

    assert {:error, :tenancy_mismatch} =
             transaction(ctx, fn ->
               endpoint!(ctx, secret_ref: invalid.ref, secret_kind: @kind)
               Transitions.attach(ctx.endpoint, invalid.ref, tenant: 17)
             end)

    assert Ash.read!(ctx.endpoint, authorize?: false, tenant: 17) == []
    assert :ok = Transitions.cleanup(ctx.endpoint, invalid.ref, tenant: 17, now: @clock)
    assert stored(ctx, invalid).state == :retired
  end

  def storage_configuration(ctx) do
    if ctx.storage == :sqlite, do: start_alternate_repo(ctx)

    for opts <- [
          [key_registry: ctx.endpoint],
          [tenant_type: :string],
          [tenancy?: false],
          [
            repo:
              if(ctx.storage == :sqlite,
                do: RegistryOtherRepo,
                else: AshHooks.Test.RegistryRepo
              )
          ]
        ] do
      errors =
        Spark.Test.dsl_errors do
          compile_endpoint(ctx, unique(ctx, "StorageGuard"), opts)
        end

      assert [{_, [_ | _]}] = errors
    end

    resource = unique(ctx, "StandardCustody")
    compile_endpoint(ctx, resource, legacy_key_lifecycle: :off)
    assert Info.attribute(resource, :secret_kind)
    assert is_nil(Info.attribute(resource, :legacy_secret_kind))

    if ctx.storage == :sqlite,
      do: assert(RegistryOtherRepo.min_sqlite_version().major == 3)
  end

  defp start_alternate_repo(ctx) do
    Application.put_env(
      :ash_hooks,
      RegistryOtherRepo,
      Application.fetch_env!(:ash_hooks, ctx.repo)
    )

    {:ok, instance} = RegistryOtherRepo.start_link()
    Process.unlink(instance)

    on_exit(fn ->
      Supervisor.stop(instance)
      Application.delete_env(:ash_hooks, RegistryOtherRepo)
    end)

    assert {:ok, %{rows: [[1]]}} =
             RegistryOtherRepo.transaction(fn ->
               RegistryOtherRepo.query!("SELECT 1", [], log: false)
             end)
  end

  def unscoped_disposal(ctx) do
    registry = unique(ctx, "UnscopedRegistry")
    endpoint = unique(ctx, "UnscopedEndpoint")
    ctx = %{ctx | registry: registry, endpoint: endpoint} |> Map.put(:tenancy?, false)
    compile_registry(ctx)
    on_exit(fn -> purge([registry, endpoint]) end)
    compile_endpoint(ctx, endpoint, tenancy?: false)
    assert {:ok, row} = Transitions.issue(endpoint, @kind, now: @clock)
    assert is_nil(row.custody_tenant)
    assert :ok = ctx.custodian.store(row.ref, @material, nil, @kind)
    owner = attach!(ctx, row)
    Ash.destroy!(owner, authorize?: false)
    assert {:ok, %{destroyed: 1}} = KeyRegistry.sweep(registry)
    assert {:ok, []} = KeyRegistry.pending(registry)
    assert {:error, :not_destroy_failed} = KeyRegistry.rearm(registry, row.ref)
    assert {:ok, 1} = KeyRegistry.prune(registry, before: DateTime.add(DateTime.utc_now(), 60))
    assert {:error, :ref_destroyed} = ctx.custodian.store(row.ref, @material, nil, @kind)
  end

  def primary_identity(ctx) do
    registry = unique(ctx, "AdditionalPrimaryKey")
    on_exit(fn -> purge([registry]) end)

    errors =
      Spark.Test.dsl_errors do
        compile_registry(%{ctx | registry: registry} |> Map.put(:extra_pk?, true))
      end

    assert [{^registry, [%Spark.Error.DslError{} = error]}] = errors
    assert Exception.message(error) =~ "sole primary key"
  end

  def scheduled_destruction(ctx) do
    {row, owner} = attached!(ctx)
    at = DateTime.add(@clock, 60)

    assert {:ok, :ok} =
             transaction(ctx, fn ->
               update!(owner, %{secret_ref: "replacement-host-key", secret_kind: nil})
               assert :ok = Transitions.retire(ctx.endpoint, row.ref, at, tenant: 17)
               :ok
             end)

    assert {:ok, _} = sweep(ctx)
    assert stored(ctx, row).state == :retired
    assert {:ok, _} = ctx.custodian.sign(row.ref, "17", @kind, "message")
    assert {:ok, _} = sweep(ctx, now: at)
    assert stored(ctx, row).state == :destroyed
  end

  def destroy_event(_event, measurements, metadata, pid),
    do: send(pid, {:destroy_event, measurements, metadata})

  def custodian_delegation(_ctx) do
    ref = "ahk_" <> Ash.UUIDv7.generate()
    assert :ok = RegistryCustodian.store(ref, @material, "17", @kind)
    assert {:ok, mac} = RegistryCustodian.sign(ref, "17", @kind, "message")
    assert :ok = RegistryCustodian.verify(ref, "17", @kind, "message", mac)
    assert {:ok, <<_::128>>} = RegistryCustodian.fingerprint(ref, "17", @kind)
    assert {:error, :no_public_half} = RegistryCustodian.public_key(ref, "17", @kind)
    assert :ok = RegistryCustodian.destroy(ref, "17")
  end

  def repo(_resource, _type), do: Process.get(:registry_wrong_repo, AshHooks.Test.RegistryRepo)

  defp issue(ctx, opts \\ []),
    do: Transitions.issue(ctx.endpoint, @kind, Keyword.merge([tenant: 17, now: @clock], opts))

  defp sweep(ctx, opts \\ []),
    do: KeyRegistry.sweep(ctx.registry, Keyword.merge([tenant: 17, now: @clock], opts))

  defp stored(ctx, row), do: Ash.get!(ctx.registry, row.ref, authorize?: false, tenant: 17)

  defp transaction(ctx, fun),
    do:
      Ash.DataLayer.transaction(ctx.endpoint, fun, nil, %{
        type: :custom,
        tenant: 17,
        metadata: %{tenant: 17}
      })

  defp attached!(ctx, slot \\ :current) do
    kind =
      case slot do
        {:previous, _, kind} -> kind
        {:current, _, kind} -> kind
        _ -> @kind
      end

    assert {:ok, row} = Transitions.issue(ctx.endpoint, kind, tenant: 17, now: @clock)
    assert :ok = ctx.custodian.store(row.ref, @material, "17", kind)
    {row, attach!(ctx, row, slot)}
  end

  defp attach!(ctx, row, slot \\ :current) do
    params =
      case slot do
        {:current, slot, _kind} ->
          fields = AshHooks.KeyLifecycle.fields(slot)
          [{fields.ref, row.ref}, {fields.kind, row.kind}]

        :current ->
          [secret_ref: row.ref, secret_kind: row.kind]

        :previous ->
          [
            previous_secret_ref: row.ref,
            previous_secret_kind: row.kind,
            previous_secret_retired_at: @clock
          ]

        {:previous, :standard, _} ->
          [
            previous_secret_ref: row.ref,
            previous_secret_kind: row.kind,
            previous_secret_retired_at: @clock
          ]

        {:previous, :legacy, _} ->
          [
            legacy_previous_secret_ref: row.ref,
            legacy_previous_secret_kind: row.kind,
            legacy_previous_secret_retired_at: @clock
          ]
      end

    assert {:ok, owner} =
             transaction(ctx, fn ->
               owner = endpoint!(ctx, params)
               assert {:ok, attached} = Transitions.attach(ctx.endpoint, row.ref, tenant: 17)
               assert attached.owner_key == AshHooks.PrimaryKey.encode(owner)
               assert attached.owner_resource == ctx.endpoint
               owner
             end)

    owner
  end

  defp endpoint!(ctx, params) do
    params =
      Map.merge(
        %{
          url: "https://hooks.example.test/registry",
          tenant_id: 17,
          secret_ref: "host-current",
          legacy_secret_ref: "legacy-current"
        },
        Map.new(params)
      )

    ctx.endpoint
    |> Ash.Changeset.for_create(
      :create,
      Map.take(params, [
        :url,
        :tenant_id,
        :secret_ref,
        :previous_secret_ref,
        :legacy_secret_ref,
        :legacy_previous_secret_ref
      ]),
      tenant: 17
    )
    |> Ash.Changeset.force_change_attributes(params)
    |> Ash.create!(authorize?: false)
  end

  defp update!(owner, params) do
    owner
    |> Ash.Changeset.for_update(:update, %{}, tenant: 17)
    |> Ash.Changeset.force_change_attributes(params)
    |> Ash.update!(authorize?: false)
  end

  defp compile_registry(ctx) do
    storage = storage(ctx.storage, Map.get(ctx, :registry_repo, ctx.repo), ctx.registry_table)
    primary_key = if Map.get(ctx, :extra_pk?, false), do: quote(do: uuid_primary_key(:id))

    Code.compile_quoted(
      quote do
        defmodule unquote(ctx.registry) do
          use Ash.Resource,
            domain: unquote(ctx.domain),
            data_layer: unquote(ctx.layer),
            extensions: [AshHooks.KeyRegistry]

          unquote(storage)

          key_registry do
          end

          attributes do
            unquote(primary_key)
            attribute :tenant_id, :integer, allow_nil?: false, default: 17, public?: true
          end

          unquote(tenancy(Map.get(ctx, :tenancy?, true)))

          actions do
            defaults [:read]
          end
        end
      end
    )
  end

  defp compile_endpoint(ctx, name, opts) do
    settings =
      Keyword.merge(
        [
          custodian: RegistryCustodian,
          key_registry: ctx.registry,
          key_lifecycle: :on,
          legacy_key_lifecycle: :on
        ],
        opts
      )

    repo = Keyword.get(settings, :repo, ctx.repo)
    {tenant_type, settings} = Keyword.pop(settings, :tenant_type, :integer)
    {tenancy?, settings} = Keyword.pop(settings, :tenancy?, true)
    settings = Keyword.delete(settings, :repo) |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    options = Enum.map(settings, fn {key, value} -> {key, [], [value]} end)
    storage = storage(ctx.storage, repo, ctx.endpoint_table)

    definitions =
      Code.compile_quoted(
        quote do
          defmodule unquote(name) do
            use Ash.Resource,
              domain: unquote(ctx.domain),
              data_layer: unquote(ctx.layer),
              extensions: [AshHooks.Endpoint]

            unquote(storage)

            endpoint do
              (unquote_splicing(options))
            end

            attributes do
              attribute :tenant_id, unquote(tenant_type), allow_nil?: false, public?: true
            end

            unquote(tenancy(tenancy?))

            actions do
              defaults [:read, :destroy, create: :*, update: :*]
            end
          end
        end
      )

    if name != ctx.endpoint, do: on_exit(fn -> purge(Enum.map(definitions, &elem(&1, 0))) end)
    name
  end

  defp tenancy(true) do
    quote do
      multitenancy do
        strategy :attribute
        attribute :tenant_id
      end
    end
  end

  defp tenancy(false), do: nil

  defp storage(name, repo, table),
    do:
      {name, [],
       [
         [
           do:
             quote do
               repo(unquote(Macro.escape(repo)))
               table unquote(table)
             end
         ]
       ]}

  defp create_tables(ctx) do
    binary = if ctx.storage == :postgres, do: "bytea", else: "blob"
    uuid = if ctx.storage == :postgres, do: "uuid", else: "text"
    json = if ctx.storage == :postgres, do: "jsonb", else: "text"
    time = if ctx.storage == :postgres, do: "timestamp(6) without time zone", else: "text"

    ctx.repo.query!(
      "CREATE TABLE #{ctx.registry_table} (ref text PRIMARY KEY, tenant_id bigint NOT NULL, kind #{binary} NOT NULL, owner_resource text NOT NULL, owner_key #{json}, state text NOT NULL, custody_tenant text, issued_at #{time} NOT NULL, destroy_after #{time}, attempts bigint NOT NULL DEFAULT 0, next_attempt_at #{time}, destroy_generation bigint NOT NULL DEFAULT 0, last_error text, inserted_at #{time} NOT NULL, updated_at #{time} NOT NULL)"
    )

    columns =
      for slot <- [:standard, :legacy],
          name <- [
            :created_at,
            :first_used_at,
            :previous_created_at,
            :previous_first_used_at,
            :retired_at
          ],
          do: "#{Map.fetch!(AshHooks.KeyLifecycle.fields(slot), name)} #{time}"

    columns = ["secret_retired_at #{time}" | columns]

    ctx.repo.query!(
      "CREATE TABLE #{ctx.endpoint_table} (id #{uuid} PRIMARY KEY, tenant_id bigint NOT NULL, url text NOT NULL, status text NOT NULL DEFAULT 'enabled', secret_ref text NOT NULL, previous_secret_ref text, legacy_secret_ref text, legacy_previous_secret_ref text, secret_kind #{binary}, previous_secret_kind #{binary}, legacy_secret_kind #{binary}, legacy_previous_secret_kind #{binary}, #{Enum.join(columns, ", ")})"
    )
  end

  defp native_id(%{storage: :postgres}, id), do: Ecto.UUID.dump!(id)
  defp native_id(_ctx, id), do: id

  defp unique(ctx, name),
    do: Module.concat(ctx.endpoint, "#{name}#{System.unique_integer([:positive])}")

  defp purge(modules),
    do:
      Enum.each(modules, fn module ->
        :code.purge(module)
        :code.delete(module)
      end)
end

defmodule AshHooks.Test.RegistryCustodian do
  @moduledoc false
  @behaviour AshHooks.Custody

  defp custodian, do: Process.get(:registry_custodian, AshHooks.Test.Custodian)
  @impl true
  def store(ref, material, tenant, kind), do: custodian().store(ref, material, tenant, kind)
  @impl true
  def sign(ref, tenant, kind, input), do: custodian().sign(ref, tenant, kind, input)
  @impl true
  def verify(ref, tenant, kind, input, mac), do: custodian().verify(ref, tenant, kind, input, mac)
  @impl true
  def public_key(ref, tenant, kind), do: custodian().public_key(ref, tenant, kind)
  @impl true
  def fingerprint(ref, tenant, kind), do: custodian().fingerprint(ref, tenant, kind)
  @impl true
  def destroy(ref, tenant) do
    result = custodian().destroy(ref, tenant)

    case Process.get(:registry_destroy_answers, []) do
      [] ->
        result

      [answer | rest] ->
        Process.put(:registry_destroy_answers, rest)

        case answer do
          :ok ->
            result

          {:delay, parent, result} ->
            send(parent, {:destroy_waiting, self(), ref, tenant})

            receive do
              :finish_destroy -> result
            end

          result ->
            result
        end
    end
  end
end
