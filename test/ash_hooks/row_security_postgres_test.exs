defmodule AshHooks.RowSecurityPostgresTest.Repo do
  use AshPostgres.Repo,
    otp_app: :ash_hooks,
    warn_on_missing_ash_functions?: false

  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  def on_transaction_begin(reason) do
    tenant = reason[:tenant]

    if not is_nil(tenant) do
      value = to_string(Ash.ToTenant.to_tenant(tenant, nil))

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

  for configuration <- [:primary, :split] do
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

    @tag configuration: configuration
    test "transaction_lifetime with #{configuration} reads", context do
      Cases.transaction_lifetime(context)
    end

    @tag :real_receiver
    @tag configuration: configuration
    test "worker_phases with #{configuration} reads", context do
      Cases.worker_phases(context)
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
