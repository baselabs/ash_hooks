defmodule AshHooks.InboundLegacyAdoptionTest do
  defmodule Repo do
    use AshSqlite.Repo, otp_app: :ash_hooks

    def write_transactions?, do: true
  end

  defmodule Ledger do
    use Ash.Resource,
      domain: AshHooks.InboundLegacyAdoptionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("inbound_legacy_adoption_ledgers")
      repo(AshHooks.InboundLegacyAdoptionTest.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
      timestamps()
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :hub_spot_v3 do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundLegacyAdoptionTest, :secret, []}
      end

      inbound :custom_identity do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundLegacyAdoptionTest, :secret, []}
        event_id(&AshHooks.InboundLegacyAdoptionTest.explicit_event_id/1)
      end

      inbound :unsupported_identity do
        secret {AshHooks.InboundLegacyAdoptionTest, :secret, []}
      end
    end
  end

  defmodule EventIdKeyLedger do
    use Ash.Resource,
      domain: AshHooks.InboundLegacyAdoptionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("inbound_legacy_adoption_ledgers")
      repo(AshHooks.InboundLegacyAdoptionTest.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:external_event_id, :string, primary_key?: true, allow_nil?: false)
      attribute(:account_id, :string, allow_nil?: false)
      timestamps()
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :hub_spot_v3 do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundLegacyAdoptionTest, :secret, []}
      end
    end
  end

  defmodule NoInsertedAtLedger do
    use Ash.Resource,
      domain: AshHooks.InboundLegacyAdoptionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("inbound_legacy_adoption_ledgers")
      repo(AshHooks.InboundLegacyAdoptionTest.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :hub_spot_v3 do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundLegacyAdoptionTest, :secret, []}
      end
    end
  end

  defmodule RejectingUpdateLedger do
    use Ash.Resource,
      domain: AshHooks.InboundLegacyAdoptionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("inbound_legacy_adoption_ledgers")
      repo(AshHooks.InboundLegacyAdoptionTest.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
      timestamps()
    end

    validations do
      validate(attribute_equals(:external_event_id, "blocked-by-validation"), on: [:update])
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :hub_spot_v3 do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundLegacyAdoptionTest, :secret, []}
      end
    end
  end

  defmodule LedgerNoTransactions do
    use Ash.Resource,
      domain: AshHooks.InboundLegacyAdoptionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("inbound_legacy_adoption_ledgers")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
      timestamps()
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :hub_spot_v3 do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundLegacyAdoptionTest, :secret, []}
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(Ledger)
      resource(LedgerNoTransactions)
      resource(EventIdKeyLedger)
      resource(NoInsertedAtLedger)
      resource(RejectingUpdateLedger)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.InboundDelivery.LegacyAdoption
  alias AshHooks.Ingress
  alias AshHooks.Provider.HubSpotV3

  @table "inbound_legacy_adoption_ledgers"

  setup_all do
    config = Application.fetch_env!(:ash_hooks, AshHooks.Test.Repo)
    Application.put_env(:ash_hooks, Repo, config)

    on_exit(fn ->
      AshHooks.Test.Repo.query!("DROP TABLE IF EXISTS #{@table}")
      Application.delete_env(:ash_hooks, Repo)
    end)

    start_supervised!(Repo)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@table} (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      external_event_id TEXT NOT NULL,
      external_event_type TEXT,
      payload TEXT NOT NULL,
      payload_digest TEXT NOT NULL,
      status TEXT NOT NULL,
      fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT,
      error_class TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      account_id TEXT NOT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_unique_ingest_index ON #{@table} (provider, external_event_id, account_id)"
    )

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@table}")
    :ok
  end

  def secret, do: {:ok, "unused-in-adoption"}
  def explicit_event_id(_payload), do: {:ok, "host-owned"}

  test "processed representative survives, siblings become terminal, audit is complete, rerun is idempotent" do
    first = event(0)
    retry = event(5)
    first_id = legacy_row(first, :received, ~U[2026-10-06 10:00:00.000000Z])
    processed_id = legacy_row(retry, :processed, ~U[2026-10-06 10:01:00.000000Z])
    {:ok, canonical} = HubSpotV3.event_identity([first])

    assert {:error, :ingress_not_quiesced} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3, scope: %{account_id: "acct-a"})

    assert {:ok, plan} =
             Ingress.plan_legacy_identity_adoption(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"}
             )

    assert plan.unresolved == []
    assert length(plan.groups) == 1
    assert length(plan.audit) == 2
    assert Enum.all?(plan.audit, &is_binary(&1.before_external_event_id))
    assert Enum.all?(plan.audit, &is_binary(&1.after_external_event_id))

    assert {:ok, applied} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               quiesced?: true
             )

    assert length(applied.audit) == 2

    rows = rows()
    representative = Enum.find(rows, &(&1.id == processed_id))
    sibling = Enum.find(rows, &(&1.id == first_id))

    assert representative.external_event_id == canonical
    assert representative.status == :processed
    assert sibling.status == :superseded
    assert sibling.error_class == "legacy_identity_superseded"
    assert sibling.payload == [first]
    assert sibling.payload_digest == digest(first)

    before = snapshot(rows)

    assert {:ok, _rerun} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               quiesced?: true
             )

    assert snapshot(rows()) == before
  end

  test "unresolved payload blocks every write until an explicit canonical mapping is supplied" do
    old_id = legacy_row(%{}, :failed_permanent, ~U[2026-10-06 11:00:00.000000Z])
    [before] = rows()

    assert {:error, %{reason: :unresolved_payloads, unresolved: [unresolved]}} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               quiesced?: true
             )

    assert unresolved.external_event_id == digest(%{})
    assert snapshot(rows()) == snapshot([before])

    assert {:ok, _} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               canonical_ids: %{digest(%{}) => "host-canonical-id"},
               quiesced?: true
             )

    [after_row] = rows()
    assert after_row.id == old_id
    assert after_row.external_event_id == "host-canonical-id"
  end

  test "host custom extractors are unchanged and excluded from adoption" do
    assert {:error, :custom_event_id_unchanged} =
             Ingress.plan_legacy_identity_adoption(Ledger, :custom_identity,
               scope: %{account_id: "acct-a"}
             )
  end

  test "default entry points and validation failures remain bounded" do
    assert {:error, :inbound_not_found} = LegacyAdoption.plan(Ledger, :missing)
    assert {:error, :ingress_not_quiesced} = LegacyAdoption.apply(Ledger, :hub_spot_v3)

    assert {:error, :partition_scope_mismatch} =
             LegacyAdoption.plan(Ledger, :hub_spot_v3, scope: "not-a-map")

    assert {:error, :provider_identity_not_supported} =
             LegacyAdoption.plan(Ledger, :unsupported_identity, scope: %{account_id: "acct-a"})

    assert {:error, :inserted_at_required} =
             LegacyAdoption.plan(NoInsertedAtLedger, :hub_spot_v3, scope: %{account_id: "acct-a"})
  end

  test "a nonrepresentative canonical occupant receives a stable superseded identity" do
    occupant_payload = %{}
    representative_payload = %{"redacted" => true}
    occupant_id = legacy_row(occupant_payload, :failed_permanent, ~U[2026-10-06 12:15:00Z])
    legacy_row(representative_payload, :processed, ~U[2026-10-06 12:16:00Z])
    canonical = "canonical-target"

    Repo.query!("UPDATE #{@table} SET external_event_id = ? WHERE id = ?", [
      canonical,
      occupant_id
    ])

    assert {:ok, plan} =
             LegacyAdoption.plan(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               canonical_ids: %{
                 canonical => canonical,
                 digest(representative_payload) => canonical
               }
             )

    occupant = Enum.find(plan.audit, &(&1.before_key == %{"id" => occupant_id}))
    assert occupant.representative == false
    assert String.starts_with?(occupant.after_external_event_id, "superseded:v1:")
  end

  test "an existing superseded identity is preserved and an event-id primary key is updated in audit" do
    occupant_payload = %{}
    representative_payload = %{"redacted" => true}
    occupant_id = legacy_row(occupant_payload, :failed_permanent, ~U[2026-10-06 12:30:00Z])
    legacy_row(representative_payload, :processed, ~U[2026-10-06 12:31:00Z])
    canonical = "superseded:v1:already-stable"

    Repo.query!("UPDATE #{@table} SET external_event_id = ? WHERE id = ?", [
      canonical,
      occupant_id
    ])

    mappings = %{
      canonical => canonical,
      digest(representative_payload) => canonical
    }

    assert {:ok, plan} =
             LegacyAdoption.plan(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               canonical_ids: mappings
             )

    occupant = Enum.find(plan.audit, &(&1.before_key == %{"id" => occupant_id}))
    assert occupant.after_external_event_id == canonical

    assert {:ok, event_key_plan} =
             LegacyAdoption.plan(EventIdKeyLedger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               canonical_ids: mappings
             )

    representative = Enum.find(event_key_plan.audit, & &1.representative)
    assert representative.after_key == %{"external_event_id" => canonical}
  end

  test "a transaction-disabled data layer rejects adoption before changing a row" do
    legacy_row(event(0), :received, ~U[2026-10-06 11:30:00.000000Z])
    before = complete_snapshot(rows(LedgerNoTransactions))

    assert Ash.DataLayer.can?(:transact, Ledger)
    refute Ash.DataLayer.can?(:transact, LedgerNoTransactions)

    assert {:error, :transactions_not_supported} =
             Ingress.adopt_legacy_identity(LedgerNoTransactions, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               quiesced?: true
             )

    assert complete_snapshot(rows(LedgerNoTransactions)) == before
  end

  test "a partition scope mismatch remains an error without changing a row" do
    legacy_row(event(0), :received, ~U[2026-10-06 11:45:00.000000Z])
    before = complete_snapshot(rows())

    assert {:error, :partition_scope_mismatch} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3,
               scope: %{},
               quiesced?: true
             )

    assert complete_snapshot(rows()) == before
  end

  test "a canonical target occupied by a different moving group is reported before any write" do
    first_payload = %{}
    second_payload = %{"redacted" => true}
    first_id = legacy_row(first_payload, :received, ~U[2026-10-06 12:00:00.000000Z])
    second_id = legacy_row(second_payload, :failed_permanent, ~U[2026-10-06 12:01:00.000000Z])
    first_old_id = digest(first_payload)
    second_old_id = digest(second_payload)
    before = snapshot(rows())

    mappings = %{
      first_old_id => second_old_id,
      second_old_id => "second-canonical-id"
    }

    assert {:ok, %{conflicts: [conflict]}} =
             Ingress.plan_legacy_identity_adoption(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               canonical_ids: mappings
             )

    assert conflict.canonical_event_id == second_old_id
    assert conflict.source_key == %{"id" => first_id}
    assert conflict.occupied_key == %{"id" => second_id}
    assert conflict.occupied_next_event_id == "second-canonical-id"

    assert {:error, %{reason: :canonical_identity_conflicts, conflicts: [^conflict]}} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               canonical_ids: mappings,
               quiesced?: true
             )

    assert snapshot(rows()) == before
  end

  test "a real database failure after a sibling write rolls back the entire adoption partition" do
    sibling_payload = event(0)
    representative_payload = event(5)

    sibling_id =
      legacy_row(sibling_payload, :received, ~U[2026-10-06 13:00:00.000000Z])

    representative_id =
      legacy_row(representative_payload, :processed, ~U[2026-10-06 13:01:00.000000Z])

    before = complete_snapshot(rows())

    Repo.query!("CREATE TABLE inbound_adoption_write_probe (marker TEXT NOT NULL)")

    Repo.query!("""
    CREATE TRIGGER inbound_adoption_record_sibling
    AFTER UPDATE ON #{@table}
    WHEN OLD.id = '#{sibling_id}'
    BEGIN
      INSERT INTO inbound_adoption_write_probe (marker) VALUES ('sibling-written');
    END
    """)

    Repo.query!("""
    CREATE TRIGGER inbound_adoption_fail_representative
    BEFORE UPDATE ON #{@table}
    WHEN OLD.id = '#{representative_id}'
      AND EXISTS (
        SELECT 1 FROM inbound_adoption_write_probe WHERE marker = 'sibling-written'
      )
    BEGIN
      SELECT RAISE(ABORT, 'forced representative adoption failure');
    END
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS inbound_adoption_fail_representative")
      Repo.query!("DROP TRIGGER IF EXISTS inbound_adoption_record_sibling")
      Repo.query!("DROP TABLE IF EXISTS inbound_adoption_write_probe")
    end)

    assert {:error, _database_error} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               quiesced?: true
             )

    assert [[0]] = Repo.query!("SELECT count(*) FROM inbound_adoption_write_probe").rows
    assert complete_snapshot(rows()) == before
  end

  test "a partition change returning no updated row rolls back without partial adoption" do
    payload = event(0)
    row_id = legacy_row(payload, :processed, ~U[2026-10-06 13:15:00.000000Z])
    before = complete_snapshot(rows())

    Repo.query!("""
    CREATE TRIGGER inbound_adoption_ignore_changed_partition
    BEFORE UPDATE ON #{@table}
    WHEN OLD.id = '#{row_id}'
    BEGIN
      SELECT RAISE(IGNORE);
    END
    """)

    on_exit(fn ->
      Repo.query!("DROP TRIGGER IF EXISTS inbound_adoption_ignore_changed_partition")
    end)

    assert {:error, _partition_changed} =
             LegacyAdoption.apply(Ledger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               quiesced?: true
             )

    assert complete_snapshot(rows()) == before
  end

  test "an atomic validation failure returns the bulk error without changing the partition" do
    legacy_row(event(0), :processed, ~U[2026-10-06 13:30:00.000000Z])
    before = complete_snapshot(rows(RejectingUpdateLedger))

    assert {:error, error} =
             LegacyAdoption.apply(RejectingUpdateLedger, :hub_spot_v3,
               scope: %{account_id: "acct-a"},
               quiesced?: true
             )

    assert Exception.message(error) =~ "blocked-by-validation"
    assert complete_snapshot(rows(RejectingUpdateLedger)) == before
  end

  defp event(attempt) do
    %{
      "subscriptionType" => "object.associationChange",
      "objectTypeId" => "2-123456",
      "objectId" => 10,
      "associatedObjectId" => 20,
      "associationType" => "custom_to_contact",
      "attemptNumber" => attempt
    }
  end

  defp legacy_row(payload, status, inserted_at) do
    id = Ash.UUID.generate()
    old_identity = digest(payload)

    Repo.query!(
      "INSERT INTO #{@table} (id, provider, external_event_id, external_event_type, payload, payload_digest, status, account_id, inserted_at, updated_at) VALUES (?, 'hub_spot_v3', ?, 'object_association_change', ?, ?, ?, 'acct-a', ?, ?)",
      [
        id,
        old_identity,
        Jason.encode!([payload]),
        old_identity,
        status,
        DateTime.to_iso8601(inserted_at),
        DateTime.to_iso8601(inserted_at)
      ]
    )

    id
  end

  defp digest(payload),
    do: :crypto.hash(:sha256, Jason.encode!([payload])) |> Base.encode16(case: :lower)

  defp rows(resource \\ Ledger), do: Ash.read!(resource, authorize?: false)

  defp snapshot(rows) do
    rows
    |> Enum.map(&{&1.id, &1.external_event_id, &1.status, &1.error_class, &1.payload_digest})
    |> Enum.sort()
  end

  defp complete_snapshot(rows) do
    rows
    |> Enum.map(fn row ->
      {
        row.id,
        row.external_event_id,
        row.status,
        row.error_class,
        row.payload_digest,
        row.payload
      }
    end)
    |> Enum.sort()
  end
end
