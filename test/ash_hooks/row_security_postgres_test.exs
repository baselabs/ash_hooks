defmodule AshHooks.RowSecurityPostgresTest.Repo do
  use AshPostgres.Repo,
    otp_app: :ash_hooks,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  def on_transaction_begin(reason) do
    tenant = reason[:tenant]

    if not is_nil(tenant) do
      value =
        case reason do
          %{metadata: %{resource: resource}} ->
            to_string(Ash.ToTenant.to_tenant(tenant, resource))

          _transact ->
            to_string(tenant)
        end

      %{rows: [[setting]]} =
        query!("SELECT set_config('ash_hooks_test.tenant', $1, true)", [value], log: false)

      :telemetry.execute([:row_security, :begin], %{}, %{tenant: tenant, setting: setting})
    end
  end
end

defmodule AshHooks.RowSecurityPostgresTest.ReadRepo do
  use AshPostgres.Repo,
    otp_app: :ash_hooks,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end

defmodule AshHooks.RowSecurityPostgresTest do
  use ExUnit.Case, async: false
  alias AshHooks.RowSecurityPostgresTest.{ReadRepo, Repo}
  alias AshHooks.Test.RowSecurityCases, as: Cases
  @moduletag :postgres

  setup_all do
    Cases.setup_postgres(__MODULE__, Repo, ReadRepo)
  end

  setup context do
    Cases.clean(context)
  end

  test "real restricted roles and forced policies deny unbound access", context do
    Cases.unbound_access(context)
  end

  if Code.ensure_loaded?(Oban) do
    test "both Oban logins are restricted roles under forced policies", context do
      Cases.oban_role_access(context)
    end

    test "the runtime instance admits tenant jobs but cannot fetch or update them", context do
      Cases.oban_runtime_isolation(context)
    end

    test "the unbound engine stages, rescues, and prunes both tenants' jobs", context do
      Cases.oban_engine_maintenance(context)
    end
  end

  for configuration <- [:primary, :split] do
    @tag configuration: configuration
    test "host rollback removes the joined enqueue failure with #{configuration} reads",
         context do
      Cases.joined_enqueue_rollback(context)
    end

    @tag configuration: configuration
    test "joined pruning rolls back when history deletion fails with #{configuration} reads",
         context do
      Cases.joined_prune_failure(context)
    end

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
    test "a struct tenant binds its key for the phase's resources with #{configuration} reads",
         context do
      Cases.struct_tenant(context)
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
    @tag :observation
    test "tracking-off counts exclude retained verification failures with #{configuration} reads",
         context do
      Cases.tracking_off_counts(context)
    end

    @tag configuration: configuration
    @tag :observation
    test "observation read failures preserve endpoint evidence with #{configuration} reads",
         context do
      Cases.observation_reads(context)
    end

    @tag configuration: configuration
    @tag :observation
    test "inbound_phases with #{configuration} reads", context do
      Cases.inbound_phases(context)
    end

    @tag configuration: configuration
    test "inline_refusal with #{configuration} reads", context do
      Cases.inline_refusal(context)
    end

    @tag configuration: configuration
    test "transaction_lifetime with #{configuration} reads", context do
      Cases.transaction_lifetime(context)
    end

    @tag :real_receiver
    @tag configuration: configuration
    test "worker_phases with #{configuration} reads", context do
      Cases.worker_phases(context)
    end

    if Code.ensure_loaded?(Oban) do
      @tag :real_receiver
      @tag configuration: configuration
      test "the unbound engine completes both tenants' jobs with #{configuration} reads",
           context do
        Cases.oban_engine_delivery(context)
      end

      @tag :real_receiver
      @tag configuration: configuration
      test "the engine schedules real HTTP retries with #{configuration} reads", context do
        Cases.oban_engine_retry(context)
      end

      @tag :real_receiver
      @tag capture_log: true
      @tag configuration: configuration
      test "the engine retries and discards finalization errors with #{configuration} reads",
           context do
        Cases.oban_engine_errors(context)
      end
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
    test "source phases with #{configuration} reads", context do
      Cases.source_phases(context)
    end

    @tag configuration: configuration
    test "issuing phases with #{configuration} reads", context do
      Cases.issuing_phases(context)
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

if Code.ensure_loaded?(Oban) do
  for {shape, tenant} <- [integer: 17, atom: :tenant_atom, custom: "mixed"] do
    defmodule Module.concat(AshHooks.RowSecurityTenantShapeTest, Macro.camelize(to_string(shape))) do
      use ExUnit.Case, async: false
      alias AshHooks.RowSecurityPostgresTest.{ReadRepo, Repo}
      alias AshHooks.Test.RowSecurityCases, as: Cases
      @moduletag :postgres
      @moduletag :real_receiver
      @shape shape
      @tenant tenant

      setup_all do
        Cases.setup_postgres(__MODULE__, Repo, ReadRepo, @shape)
      end

      test "the queue round-trips the tenant through forced ledger and job policies", context do
        Cases.oban_tenant_shape(context, @tenant)
      end
    end
  end
end
