defmodule AshHooks.RowSecurityTest.Repo do
  use AshSqlite.Repo, otp_app: :ash_hooks
  def write_transactions?, do: Application.get_env(:ash_hooks, :row_security_transactions, true)
  def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
end

defmodule AshHooks.RowSecurityTest.ReadRepo do
  use AshSqlite.Repo, otp_app: :ash_hooks
  def write_transactions?, do: true
  def min_sqlite_version, do: %Version{major: 3, minor: 54, patch: 1}
end

defmodule AshHooks.RowSecurityTest do
  use ExUnit.Case, async: false
  alias AshHooks.RowSecurityTest.ReadRepo
  alias AshHooks.Test.RowSecurityCases, as: Cases

  setup_all do
    Cases.setup_sqlite(__MODULE__, ReadRepo)
  end

  setup context do
    Cases.clean(context)
  end

  test "a data layer without transactions preserves the operation result", context do
    refute Ash.DataLayer.can?(:transact, context.emitter)
    assert AshHooks.Phase.context(context.emitter) == %{}
    assert :ok = AshHooks.Phase.outside_transaction(context.emitter)

    assert {:error, :unsupported_phase} =
             AshHooks.Phase.run(context.emitter, "tenant_a", fn ->
               {:error, :unsupported_phase}
             end)
  end

  test "the driver refuses a repository transaction even with Ash write transactions disabled",
       context do
    Application.put_env(:ash_hooks, :row_security_transactions, false)
    on_exit(fn -> Application.delete_env(:ash_hooks, :row_security_transactions) end)
    refute Ash.DataLayer.can?(:transact, context.delivery)

    assert {:ok, :ok} =
             context.repo.transaction(fn ->
               assert context.repo.in_transaction?()
               refute Ash.DataLayer.in_transaction?(context.delivery)

               assert {:error, :inside_transaction} =
                        AshHooks.Delivery.run(%{},
                          deliveries: context.delivery,
                          endpoints: context.endpoint,
                          attempt_timeout: 50,
                          finalization_allowance: 50
                        )

               assert {:error, :inside_transaction} =
                        AshHooks.Delivery.test_send(
                          struct(context.endpoint, id: Ash.UUID.generate()),
                          deliveries: context.delivery,
                          type: :event,
                          tenant: "tenant_a"
                        )

               :ok
             end)
  end

  for configuration <- [:primary, :split] do
    for failure <- [:refusal, :read_error] do
      @tag configuration: configuration
      test "joined #{failure} preserves host writes with #{configuration} reads", context do
        Cases.joined_phase_error(context, unquote(failure))
      end
    end

    @tag configuration: configuration
    test "a failed package write rolls back the host with #{configuration} reads", context do
      Cases.joined_write_failure(context)
    end

    @tag configuration: configuration
    test "driver refusal inside a host transaction with #{configuration} reads", context do
      Cases.driver_refusal(context)
    end

    @tag configuration: configuration
    test "outbound_phases with #{configuration} reads", context do
      Cases.outbound_phases(context)
    end

    @tag configuration: configuration
    test "subscription pages retain the tenant phase with #{configuration} reads", context do
      Cases.subscription_pages(context)
    end

    @tag configuration: configuration
    test "enqueue repair and route binding phases with #{configuration} reads", context do
      Cases.enqueue_repair(context)
    end

    @tag configuration: configuration
    test "inbound_phases with #{configuration} reads", context do
      Cases.inbound_phases(context)
    end

    @tag configuration: configuration
    test "inline_refusal with #{configuration} reads", context do
      Cases.inline_refusal(context)
    end

    for operation <- [
          :resend,
          :delivery_replay,
          :event_replay,
          :event_replay_missing,
          :reconcile,
          :public_reconcile
        ] do
      @tag configuration: configuration
      test "#{operation} inherits the driver refusal with #{configuration} reads", context do
        Cases.inherited_refusal(context, unquote(operation))
      end
    end

    if Code.ensure_loaded?(Oban) do
      @tag configuration: configuration
      test "the generated worker inherits the driver refusal with #{configuration} reads",
           context do
        Cases.inherited_refusal(context, :worker)
      end
    end

    @tag configuration: configuration
    test "registry phases with #{configuration} reads", context do
      Cases.registry_phases(context)
    end

    @tag configuration: configuration
    test "tracer context with #{configuration} reads", context do
      Cases.tracer_context(context)
    end

    @tag :real_receiver
    @tag configuration: configuration
    test "driver finalization and recovery phases with #{configuration} reads", context do
      Cases.driver_state_phases(context)
    end

    @tag :real_receiver
    @tag configuration: configuration
    test "the attempt deadline and finalizer retain tracer context with #{configuration} reads",
         context do
      Cases.tracer_deadline(context)
    end
  end
end
