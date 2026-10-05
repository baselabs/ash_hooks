defmodule AshHooks.PruneActionTest do
  @moduledoc """
  Consumer scenario (H6, the first-serious-consumer integration): an
  append-only audit-ledger consumer pins `refute :destroy in actions`
  (sirtify egr_arch_test.exs:142-145 — "the rows ARE the audit"), so the
  package's injected `destroy :prune` fails the arch pin on adoption.
  `prune_action :none` opts out of the destroy action's injection —
  deletion becomes the consumer's own surface, and the package's prune
  hooks fail LOUD with a named error instead of reaching for an action
  that no longer exists.
  """

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PruneActionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("prune_action_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end

    attributes do
      timestamps()
    end

    # the append-only posture: no destroy action at all (H6)
    outbound_delivery do
      prune_action(:none)
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.PruneActionTest.Delivery)
    end
  end

  use ExUnit.Case, async: false

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshHooks.Delivery, as: DeliveryRuntime
  alias AshHooks.Test.Repo

  @deliveries "prune_action_test_deliveries"

  # compiled at RUNTIME so the transformer's opt-out branch lights up
  # under cover (the purged-fixture pattern)
  @opted_out_resource """
  defmodule AshHooks.PruneActionTest.OptedOut do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PruneActionTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.OutboundDelivery]

    actions do
      defaults([:read])
    end

    outbound_delivery do
      prune_action(:none)
    end
  end
  """

  @default_resource """
  defmodule AshHooks.PruneActionTest.Default do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PruneActionTest.Domain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.OutboundDelivery]

    actions do
      defaults([:read])
    end
  end
  """

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY,
      event_uuid TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload BLOB NOT NULL,
      endpoint_id TEXT NOT NULL,
      subscription_id TEXT,
      signing_mode TEXT,
      status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0,
      response_status INTEGER,
      response_snippet TEXT,
      last_error TEXT,
      next_attempt_at TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
    end)

    :ok
  end

  describe "the append-only reservation (H6)" do
    test "no destroy action is injected under prune_action :none" do
      actions = ResourceInfo.actions(Delivery)

      assert :destroy not in Enum.map(actions, & &1.type),
             "the injected destroy :prune fails an append-only arch pin (H6)"

      refute ResourceInfo.action(Delivery, :prune)
    end

    test "the runtime prune hook fails LOUD with a named error, never silently" do
      assert {:error, error} = DeliveryRuntime.prune(Delivery, older_than: DateTime.utc_now())

      assert Exception.message(error) =~ "prune_action :none"
      assert Exception.message(error) =~ "deletion is the consumer's own surface"
    end

    test "the default still injects destroy :prune (byte-identical posture)" do
      assert Enum.any?(Code.compile_string(@default_resource), fn {m, _} ->
               m == AshHooks.PruneActionTest.Default
             end)

      assert ResourceInfo.action(AshHooks.PruneActionTest.Default, :prune).type == :destroy
    after
      :code.purge(AshHooks.PruneActionTest.Default)
      :code.delete(AshHooks.PruneActionTest.Default)
    end

    test "an opted-out runtime-compiled resource carries no destroy action either" do
      assert Enum.any?(Code.compile_string(@opted_out_resource), fn {m, _} ->
               m == AshHooks.PruneActionTest.OptedOut
             end)

      refute ResourceInfo.action(AshHooks.PruneActionTest.OptedOut, :prune)

      assert :destroy not in Enum.map(
               ResourceInfo.actions(AshHooks.PruneActionTest.OptedOut),
               & &1.type
             )
    after
      :code.purge(AshHooks.PruneActionTest.OptedOut)
      :code.delete(AshHooks.PruneActionTest.OptedOut)
    end
  end
end
