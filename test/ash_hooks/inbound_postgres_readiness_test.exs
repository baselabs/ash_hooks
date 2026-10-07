defmodule AshHooks.InboundPostgresReadinessTest do
  @moduledoc """
  Real-Postgres qualification for inbound composite keys, parsed attribute
  tenancy, multi-writer claim fencing, and legacy HubSpot identity adoption.

  The HubSpot lifecycle uses the vendor-published signed vector. Its fixed
  timestamp is checked against the vector timestamp through the provider's
  real verifier; no locally generated signature stands in for vendor data.
  """

  defmodule Ledger do
    @moduledoc false

    use Ash.Resource,
      domain: AshHooks.InboundPostgresReadinessTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    postgres do
      table("pg_inbound_readiness_ledgers")
      repo(AshHooks.TestPostgres.Repo)
    end

    attributes do
      attribute(:account_id, :string,
        allow_nil?: false,
        primary_key?: true,
        public?: true
      )

      uuid_v7_primary_key(:receipt_id)

      attribute(:id, :uuid,
        allow_nil?: false,
        default: &Ash.UUID.generate/0,
        public?: true
      )

      attribute(:tenant_slug, :string, allow_nil?: false, public?: true)
      timestamps()
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_slug)
      parse_attribute({__MODULE__, :parse_tenant, []})
      tenant_from_attribute({__MODULE__, :tenant_from_attribute, []})
    end

    actions do
      defaults([:read])
    end

    inbound_delivery do
      scope_identity([:account_id])
      lease_seconds(30)
    end

    webhooks do
      inbound :hub_spot_v3 do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundPostgresReadinessTest, :hubspot_secret, []}
      end

      inbound :hub_spot_v3_wide do
        provider(AshHooks.Provider.HubSpotV3)
        secret {AshHooks.InboundPostgresReadinessTest, :hubspot_secret, []}

        replay_window_seconds(
          div(abs(System.system_time(:millisecond) - 1_752_613_922_216), 1000) + 3_600
        )
      end
    end

    def parse_tenant(tenant), do: tenant |> to_string() |> String.upcase()
    def tenant_from_attribute(tenant), do: String.downcase(tenant)
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.InboundPostgresReadinessTest.Ledger)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.{Ingress, PrimaryKey}
  alias AshHooks.Provider.HubSpotV3
  alias AshHooks.TestPostgres.Repo

  @moduletag :postgres

  @table "pg_inbound_readiness_ledgers"
  @audit_table "pg_inbound_readiness_handler_audit"
  @audit_function "pg_inbound_readiness_record_update"
  @secret "cfc68c0b-4b4e-4ef8-b764-95350e4ea479"
  @method "POST"
  @uri "https://webhook.site/335453f5-94b3-49d9-b684-a55354d4b8df"
  @timestamp "1752613922216"
  @now_ms 1_752_613_922_216
  @signature "gbj1XPRvUt0noT7i7fXfTzOD4sLzQmf0VT28ZYq0EYg="
  @body ~s([{"eventId":531833541,"subscriptionId":3923621,"portalId":48807704,"appId":16111050,"occurredAt":1752613920733,"subscriptionType":"contact.creation","attemptNumber":0,"objectId":138017612137,"changeFlag":"CREATED","changeSource":"CRM_UI","sourceId":"userId:76023669"}])

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@table} (
      account_id TEXT NOT NULL,
      receipt_id UUID NOT NULL,
      id UUID NOT NULL,
      tenant_slug TEXT NOT NULL,
      provider TEXT NOT NULL,
      external_event_id TEXT NOT NULL,
      external_event_type TEXT,
      payload JSONB NOT NULL,
      payload_digest TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'received',
      fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TIMESTAMPTZ,
      error_class TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      inserted_at TIMESTAMPTZ NOT NULL,
      updated_at TIMESTAMPTZ NOT NULL,
      PRIMARY KEY (account_id, receipt_id)
    )
    """)

    Repo.query!("""
    CREATE UNIQUE INDEX IF NOT EXISTS #{@table}_unique_ingest_index
    ON #{@table} (tenant_slug, provider, external_event_id, account_id)
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@audit_table} (
      sequence BIGSERIAL PRIMARY KEY,
      account_id TEXT NOT NULL,
      receipt_id UUID NOT NULL,
      prior_status TEXT NOT NULL,
      next_status TEXT NOT NULL,
      prior_attempts INTEGER NOT NULL,
      next_attempts INTEGER NOT NULL
    )
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION #{@audit_function}() RETURNS trigger AS $$
    BEGIN
      INSERT INTO #{@audit_table}
        (account_id, receipt_id, prior_status, next_status, prior_attempts, next_attempts)
      VALUES
        (OLD.account_id, OLD.receipt_id, OLD.status, NEW.status, OLD.attempts, NEW.attempts);
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """)

    Repo.query!("DROP TRIGGER IF EXISTS record_inbound_update ON #{@table}")

    Repo.query!("""
    CREATE TRIGGER record_inbound_update
    AFTER UPDATE OF status, fencing_token, attempts ON #{@table}
    FOR EACH ROW
    WHEN (
      OLD.status IS DISTINCT FROM NEW.status OR
      OLD.fencing_token IS DISTINCT FROM NEW.fencing_token OR
      OLD.attempts IS DISTINCT FROM NEW.attempts
    )
    EXECUTE FUNCTION #{@audit_function}()
    """)

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@table}")
      Repo.query!("DROP TABLE IF EXISTS #{@audit_table}")
      Repo.query!("DROP FUNCTION IF EXISTS #{@audit_function}()")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@table}")
    Repo.query!("DELETE FROM #{@audit_table}")
    :ok
  end

  def hubspot_secret, do: {:ok, @secret}

  test "parsed tenancy isolates attacker-first rows and the full composite key fences claims" do
    attacker = ingest_row!("attacker", "shared-account", "shared-event", "attacker-id")
    victim = ingest_row!("victim", "shared-account", "shared-event", "victim-id")

    assert attacker.tenant_slug == "ATTACKER"
    assert victim.tenant_slug == "VICTIM"
    assert victim.id == "d48ee7aa-eacf-4ee1-bc82-a95dc727a60e"

    victim_key = PrimaryKey.map(victim)

    assert {:error, :lease_held} =
             Ingress.claim_delivery(Ledger, victim_key, tenant: "attacker")

    assert %{status: :received} = read!(victim_key, "victim")
    assert %{status: :received} = read!(PrimaryKey.map(attacker), "attacker")

    results =
      1..8
      |> Task.async_stream(
        fn _ -> Ingress.claim_delivery(Ledger, victim_key, tenant: "victim") end,
        max_concurrency: 8,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert [{:ok, first_token, first_claim}] =
             Enum.filter(results, &match?({:ok, _, _}, &1))

    assert first_token == 1
    assert first_claim.attempts == 1
    assert Enum.count(results, &(&1 == {:error, :lease_held})) == 7

    Repo.query!(
      "UPDATE #{@table} SET lease_expires_at = NOW() - INTERVAL '1 second' " <>
        "WHERE account_id = $1 AND receipt_id = $2",
      [victim.account_id, Ecto.UUID.dump!(victim.receipt_id)]
    )

    assert {:ok, 2, second_claim} =
             Ingress.claim_delivery(Ledger, victim_key, tenant: "victim")

    assert second_claim.attempts == 2

    assert {:error, :stale_token} =
             Ingress.mark_processed(Ledger, victim_key, first_token, tenant: "victim")

    assert :ok =
             Ingress.mark_processed(Ledger, victim_key, second_claim.fencing_token,
               tenant: "victim"
             )

    assert %{status: :processed, fencing_token: 2, attempts: 2} =
             read!(victim_key, "victim")
  end

  test "an authenticated malformed HubSpot batch is rejected before a ledger write" do
    # Locally signed negative input exercises ingress validation, not vendor conformance.
    raw_body = "[]"
    timestamp = Integer.to_string(System.system_time(:millisecond))

    signature =
      :crypto.mac(:hmac, :sha256, @secret, @method <> @uri <> raw_body <> timestamp)
      |> Base.encode64()

    context = %{
      signature: signature,
      headers: %{"x-hubspot-request-timestamp" => timestamp},
      method: @method,
      request_uri: @uri,
      tenant: "victim",
      scope: %{account_id: "malformed-batch"}
    }

    assert {:error, %AshHooks.Errors.Invalid.MalformedPayload{detail: detail}} =
             Ingress.ingest(Ledger, :hub_spot_v3, raw_body, context)

    assert detail =~ "event identity callback"
    assert [[0]] = Repo.query!("SELECT count(*) FROM #{@table}").rows
  end

  test "published HubSpot vector adopts legacy digest identity and terminal dedup cannot repeat handling" do
    assert :ok =
             HubSpotV3.verify_signature(
               @body,
               %{
                 signature: @signature,
                 headers: %{"x-hubspot-request-timestamp" => @timestamp},
                 method: @method,
                 request_uri: @uri,
                 now_ms: @now_ms
               },
               @secret
             )

    assert {:error, %AshHooks.Errors.Invalid.StaleTimestamp{}} =
             Ingress.ingest(Ledger, :hub_spot_v3, @body, vector_context("victim"))

    payload = Jason.decode!(@body)
    digest = digest(@body)
    {:ok, canonical_id} = HubSpotV3.event_identity(payload)

    legacy =
      insert_legacy!(%{
        account_id: "published-account",
        tenant: "victim",
        provider: :hub_spot_v3_wide,
        external_event_id: digest,
        payload: payload,
        payload_digest: digest,
        status: :processed,
        attempts: 3
      })

    assert {:ok, plan} =
             Ingress.plan_legacy_identity_adoption(Ledger, :hub_spot_v3_wide,
               tenant: "victim",
               scope: %{account_id: "published-account"}
             )

    assert plan.unresolved == []
    assert plan.conflicts == []
    assert [audit] = plan.audit
    assert audit.before_key == PrimaryKey.encode(legacy)
    assert audit.before_external_event_id == digest
    assert audit.after_external_event_id == canonical_id
    assert audit.canonical_event_id == canonical_id
    assert audit.before_status == :processed
    assert audit.after_status == :processed
    assert audit.payload_digest == digest

    assert {:ok, applied} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3_wide,
               tenant: "victim",
               scope: %{account_id: "published-account"},
               quiesced?: true
             )

    assert applied.unresolved == []
    assert applied.conflicts == []

    audit_count_before = audit_count()

    assert {:ok, :duplicate, duplicate} =
             Ingress.ingest(Ledger, :hub_spot_v3_wide, @body, vector_context("victim"))

    assert duplicate.status == :processed
    assert duplicate.attempts == 3
    assert audit_count() == audit_count_before

    env = %{
      name: :hub_spot_v3_wide,
      payload: payload,
      digest: digest,
      external_event_id: canonical_id,
      type_string: "contact_creation",
      scope: %{account_id: "published-account"},
      tenant: "victim"
    }

    assert {:ok, false, duplicate} = Ingress.ingest_delivery(Ledger, env)
    assert duplicate.status == :processed
    assert duplicate.attempts == 3

    key = PrimaryKey.map(duplicate)
    assert {:error, :lease_held} = Ingress.claim_delivery(Ledger, key, tenant: "victim")

    assert %{status: :processed, attempts: 3, external_event_id: ^canonical_id} =
             read!(key, "victim")

    assert {:ok, rerun} =
             Ingress.adopt_legacy_identity(Ledger, :hub_spot_v3_wide,
               tenant: "victim",
               scope: %{account_id: "published-account"},
               quiesced?: true
             )

    assert rerun.unresolved == []

    assert %{status: :processed, attempts: 3, external_event_id: ^canonical_id} =
             read!(key, "victim")
  end

  test "bounded Postgres retention sweep reports measured work and preserves nonterminal rows" do
    payload = %{"body" => String.duplicate("x", 32_768)}

    for sequence <- 1..4 do
      insert_legacy!(%{
        account_id: "retention-account",
        tenant: "retention",
        provider: :hub_spot_v3_wide,
        external_event_id: "retention-terminal-#{sequence}",
        payload: payload,
        payload_digest: digest("retention-terminal-#{sequence}"),
        status: :processed,
        attempts: sequence
      })
    end

    insert_legacy!(%{
      account_id: "retention-account",
      tenant: "retention",
      provider: :hub_spot_v3_wide,
      external_event_id: "retention-received",
      payload: payload,
      payload_digest: digest("retention-received"),
      status: :received,
      attempts: 0
    })

    memory_before = :erlang.memory(:total)

    {elapsed_microseconds, {:ok, deleted_count}} =
      :timer.tc(fn ->
        Ingress.prune(Ledger,
          tenant: "retention",
          older_than: DateTime.add(DateTime.utc_now(), 60, :second),
          batch_size: 3
        )
      end)

    memory_after = :erlang.memory(:total)

    assert deleted_count == 3

    assert [[1]] =
             Repo.query!(
               "SELECT COUNT(*) FROM #{@table} WHERE tenant_slug = $1 AND status = 'processed'",
               ["RETENTION"]
             ).rows

    assert [[1]] =
             Repo.query!(
               "SELECT COUNT(*) FROM #{@table} WHERE tenant_slug = $1 AND status = 'received'",
               ["RETENTION"]
             ).rows

    IO.puts(
      "PG inbound prune measurement: seeded_rows=5 payload_bytes=#{byte_size(Jason.encode!(payload)) * 5} " <>
        "batch_size=3 deleted=#{deleted_count} terminal_remaining=1 nonterminal_remaining=1 " <>
        "elapsed_us=#{elapsed_microseconds} memory_before=#{memory_before} " <>
        "memory_after=#{memory_after} memory_delta=#{memory_after - memory_before}"
    )
  end

  defp ingest_row!(tenant, account_id, external_event_id, marker) do
    id =
      case marker do
        "victim-id" -> "d48ee7aa-eacf-4ee1-bc82-a95dc727a60e"
        _ -> Ash.UUID.generate()
      end

    Ash.create!(
      Ledger,
      %{
        id: id,
        provider: :hub_spot_v3,
        external_event_id: external_event_id,
        external_event_type: "contact_creation",
        payload: [%{"subscriptionType" => "contact.creation", "marker" => marker}],
        payload_digest: digest(marker),
        account_id: account_id
      },
      action: :ingest,
      authorize?: false,
      tenant: tenant
    )
  end

  defp insert_legacy!(attrs) do
    receipt_id = Ash.UUIDv7.generate()
    id = Ash.UUID.generate()
    now = DateTime.utc_now()

    Repo.query!(
      """
      INSERT INTO #{@table}
        (account_id, receipt_id, id, tenant_slug, provider, external_event_id,
         external_event_type, payload, payload_digest, status, fencing_token,
         attempts, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, 'contact_creation', $7::jsonb,
              $8, $9, 0, $10, $11, $11)
      """,
      [
        attrs.account_id,
        Ecto.UUID.dump!(receipt_id),
        Ecto.UUID.dump!(id),
        String.upcase(attrs.tenant),
        Atom.to_string(attrs.provider),
        attrs.external_event_id,
        attrs.payload,
        attrs.payload_digest,
        Atom.to_string(attrs.status),
        attrs.attempts,
        now
      ]
    )

    read!(%{account_id: attrs.account_id, receipt_id: receipt_id}, attrs.tenant)
  end

  defp read!(key, tenant) do
    Ledger
    |> Ash.Query.do_filter(key)
    |> Ash.read_one!(authorize?: false, tenant: tenant)
  end

  defp audit_count do
    %{rows: [[count]]} = Repo.query!("SELECT COUNT(*) FROM #{@audit_table}")
    count
  end

  defp vector_context(tenant) do
    %{
      signature: @signature,
      headers: %{"x-hubspot-request-timestamp" => @timestamp},
      method: @method,
      request_uri: @uri,
      scope: %{account_id: "published-account"},
      tenant: tenant
    }
  end

  defp digest(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
