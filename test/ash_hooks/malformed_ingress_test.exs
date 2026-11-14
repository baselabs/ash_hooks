defmodule AshHooks.MalformedIngressTest do
  use ExUnit.Case, async: false
  @moduletag capture_log: true

  alias Ash.Resource.Info
  alias AshHooks.Ingress

  defmodule HeaderProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

    @impl true
    def handle_event(type, payload) do
      send(self(), {:handled, type, payload})
      super(type, payload)
    end
  end

  defmodule CollisionProvider do
    use AshHooks.Provider, verify: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

    @impl true
    def event_identity(_payload), do: {:ok, "shared-event"}

    @impl true
    def handle_event(type, payload) do
      send(self(), {:handled, type, payload})
      super(type, payload)
    end
  end

  defmodule SqliteLedger do
    use Ash.Resource,
      domain: AshHooks.MalformedIngressTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("malformed_ingress")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
      ingress_tracking(:on)
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
      attribute(:tenant_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :headers do
        provider(AshHooks.MalformedIngressTest.HeaderProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end

      inbound :collision do
        provider(AshHooks.MalformedIngressTest.CollisionProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end
    end
  end

  defmodule GeneratedSqliteLedger do
    use Ash.Resource,
      domain: AshHooks.MalformedIngressTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("malformed_ingress")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
      ingress_tracking(:on)
    end

    attributes do
      uuid_v7_primary_key(:id)
      attribute(:account_id, :string, allow_nil?: false)
      attribute(:tenant_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :headers do
        provider(AshHooks.MalformedIngressTest.HeaderProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end

      inbound :collision do
        provider(AshHooks.MalformedIngressTest.CollisionProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end
    end
  end

  defmodule PostgresLedger do
    use Ash.Resource,
      domain: AshHooks.MalformedIngressTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    postgres do
      table("malformed_ingress")
      repo(AshHooks.TestPostgres.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
      ingress_tracking(:on)
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
      attribute(:tenant_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :headers do
        provider(AshHooks.MalformedIngressTest.HeaderProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end

      inbound :collision do
        provider(AshHooks.MalformedIngressTest.CollisionProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end
    end
  end

  defmodule GeneratedPostgresLedger do
    use Ash.Resource,
      domain: AshHooks.MalformedIngressTest.Domain,
      data_layer: AshPostgres.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    postgres do
      table("malformed_ingress")
      repo(AshHooks.TestPostgres.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
      ingress_tracking(:on)
    end

    attributes do
      uuid_v7_primary_key(:id)
      attribute(:account_id, :string, allow_nil?: false)
      attribute(:tenant_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :headers do
        provider(AshHooks.MalformedIngressTest.HeaderProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end

      inbound :collision do
        provider(AshHooks.MalformedIngressTest.CollisionProvider)
        secret {AshHooks.MalformedIngressTest, :secret, []}
      end
    end
  end

  defmodule Domain do
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(SqliteLedger)
      resource(GeneratedSqliteLedger)
      resource(PostgresLedger)
      resource(GeneratedPostgresLedger)
    end
  end

  @table "malformed_ingress"
  @tenant "tenant-a"
  @secret "test-secret"
  @dedup [:ash_hooks, :ingress, :dedup]
  @claim [:ash_hooks, :ingress, :claim]

  setup_all do
    repos =
      [AshHooks.Test.Repo] ++
        if(System.get_env("ASH_HOOKS_POSTGRES") == "1",
          do: [AshHooks.TestPostgres.Repo],
          else: []
        )

    for repo <- repos do
      {id_type, payload_type, time_type} =
        if repo == AshHooks.Test.Repo,
          do: {"TEXT", "TEXT", "TEXT"},
          else: {"UUID", "JSONB", "TIMESTAMPTZ"}

      repo.query!("""
      CREATE TABLE #{@table} (
        id #{id_type} PRIMARY KEY, tenant_id TEXT NOT NULL, account_id TEXT NOT NULL,
        provider TEXT NOT NULL, external_event_id TEXT NOT NULL, external_event_type TEXT,
        payload #{payload_type} NOT NULL, payload_digest TEXT NOT NULL, status TEXT NOT NULL,
        fencing_token INTEGER NOT NULL DEFAULT 0, lease_expires_at #{time_type},
        error_class TEXT, attempts INTEGER NOT NULL DEFAULT 0, duplicates INTEGER NOT NULL DEFAULT 0
      )
      """)

      repo.query!("""
      CREATE UNIQUE INDEX #{@table}_unique_ingest_index
      ON #{@table} (tenant_id, provider, external_event_id, account_id)
      """)
    end

    on_exit(fn -> for repo <- repos, do: repo.query!("DROP TABLE #{@table}") end)
    {:ok, repos: repos}
  end

  setup %{repos: repos} do
    for repo <- repos, do: repo.query!("DELETE FROM #{@table}")
    handler = {__MODULE__, self()}
    :ok = :telemetry.attach_many(handler, [@dedup, @claim], &__MODULE__.capture_event/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  for {ledger, substrate} <- [
        {SqliteLedger, :sqlite},
        {GeneratedSqliteLedger, :sqlite_generated},
        {PostgresLedger, :postgres},
        {GeneratedPostgresLedger, :postgres_generated}
      ] do
    for {kind, body} <- [{:undecodable, "not json at all"}, {:scalar, "42"}] do
      if substrate in [:postgres, :postgres_generated], do: @tag(:postgres)

      test "#{substrate}: a signed #{kind} body is terminal when written and never handled" do
        ledger = unquote(ledger)
        body = unquote(body)

        assert {:ok, :created, row} = Ingress.ingest(ledger, :headers, body, ctx(body))
        refute_received {:handled, _, _}
        assert_malformed(row)
        assert row.payload_digest == digest(body)
        assert_received {:ingress, @dedup, %{source: :headers, outcome: :created}}
        refute_received {:ingress, @claim, _}
        assert [stored] = Ash.read!(ledger, authorize?: false, tenant: @tenant)
        assert_malformed(stored)
        assert {:error, :lease_held} = Ingress.claim_delivery(ledger, row.id, tenant: @tenant)
      end
    end

    if substrate in [:postgres, :postgres_generated], do: @tag(:postgres)

    test "#{substrate}: duplicate malformed bodies retain the row and count without obtaining a claim" do
      ledger = unquote(ledger)
      body = "not json at all"
      assert {:ok, :created, first} = Ingress.ingest(ledger, :headers, body, ctx(body))
      assert {:ok, :duplicate, duplicate} = Ingress.ingest(ledger, :headers, body, ctx(body))
      assert duplicate.id == first.id
      assert_malformed(duplicate)
      assert_received {:ingress, @dedup, %{source: :headers, outcome: :duplicate}}
      refute_received {:ingress, @claim, %{outcome: :claimed}}
      refute_received {:handled, _, _}
      assert [stored] = Ash.read!(ledger, authorize?: false, tenant: @tenant)
      if Info.action(ledger, :count_duplicate), do: assert(stored.duplicates == 1)
      assert_malformed(stored)
    end

    if substrate in [:postgres, :postgres_generated], do: @tag(:postgres)

    test "#{substrate}: a malformed identity collision drives the surviving received payload" do
      ledger = unquote(ledger)
      payload = %{"id" => "shared-event", "value" => "stored"}
      env = env(payload, :collision, "shared-event")
      assert {:ok, true, first} = Ingress.ingest_delivery(ledger, env)
      assert first.status == :received

      body = "not json at all"
      assert {:ok, :duplicate, duplicate} = Ingress.ingest(ledger, :collision, body, ctx(body))
      assert duplicate.id == first.id
      assert duplicate.payload == payload
      assert duplicate.payload_digest == first.payload_digest
      assert duplicate.status == :processed
      assert duplicate.error_class == nil
      assert duplicate.attempts == 1
      assert duplicate.fencing_token == 1
      assert_received {:handled, :webhook, ^payload}
      refute_received {:handled, _, _}
      assert_received {:ingress, @dedup, %{source: :collision, outcome: :duplicate}}
      assert_received {:ingress, @claim, %{outcome: :claimed}}
      assert [stored] = Ash.read!(ledger, authorize?: false, tenant: @tenant)
      if Info.action(ledger, :count_duplicate), do: assert(stored.duplicates == 1)
    end

    if substrate in [:postgres, :postgres_generated], do: @tag(:postgres)

    test "#{substrate}: a failed verification is recorded on the ledger's own key shape" do
      ledger = unquote(ledger)
      accepts_id? = :id in Info.action(ledger, :record_rejection).accept
      assert accepts_id? == Info.attribute(ledger, :id).writable?

      body = ~s({"id":"forged"})
      forged = %{ctx(body) | headers: %{"x-signature" => String.duplicate("0", 64)}}
      assert {:error, _} = Ingress.ingest(ledger, :headers, body, forged)

      assert [stored] = Ash.read!(ledger, authorize?: false, tenant: @tenant)
      assert stored.status == :failed_verification
      assert stored.external_event_id == "verify:" <> digest(body)
      refute_received {:handled, _, _}
    end

    if substrate in [:postgres, :postgres_generated], do: @tag(:postgres)

    test "#{substrate}: reaping after a malformed ingest drives nothing" do
      ledger = unquote(ledger)
      body = "not json at all"
      assert {:ok, :created, _} = Ingress.ingest(ledger, :headers, body, ctx(body))
      assert {:ok, 0} = Ingress.reap(ledger, tenant: @tenant)
      refute_received {:handled, _, _}
      refute_received {:ingress, @claim, _}
      assert [stored] = Ash.read!(ledger, authorize?: false, tenant: @tenant)
      assert_malformed(stored)
    end

    if substrate in [:postgres, :postgres_generated], do: @tag(:postgres)

    test "#{substrate}: malformed identities are isolated by tenant and every scope slot" do
      ledger = unquote(ledger)
      body = "not json at all"

      for {tenant, account} <- [
            {@tenant, "account-a"},
            {@tenant, "account-b"},
            {"tenant-b", "account-a"}
          ] do
        context = %{ctx(body) | tenant: tenant, scope: %{account_id: account}}
        assert {:ok, :created, first} = Ingress.ingest(ledger, :headers, body, context)
        assert {:ok, :duplicate, duplicate} = Ingress.ingest(ledger, :headers, body, context)
        assert duplicate.id == first.id
        assert_malformed(duplicate)
      end

      assert length(Ash.read!(ledger, authorize?: false, tenant: @tenant)) == 2
      assert length(Ash.read!(ledger, authorize?: false, tenant: "tenant-b")) == 1
      refute_received {:handled, _, _}
    end
  end

  def secret, do: {:ok, @secret}

  def capture_event(event, _measurements, metadata, sink),
    do: send(sink, {:ingress, event, metadata})

  defp ctx(body) do
    signature = :crypto.mac(:hmac, :sha256, @secret, body) |> Base.encode16(case: :lower)

    %{
      headers: %{"x-signature" => signature},
      tenant: @tenant,
      scope: %{account_id: "account-a"}
    }
  end

  defp env(payload, name, id) do
    %{
      name: name,
      external_event_id: id,
      type_string: "webhook",
      payload: payload,
      digest: digest(Jason.encode!(payload)),
      tenant: @tenant,
      scope: %{account_id: "account-a"}
    }
  end

  defp digest(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

  defp assert_malformed(row) do
    assert row.status == :failed_permanent
    assert row.error_class == "malformed_payload"
    assert row.payload == %{}
    assert row.external_event_type == nil
    assert row.attempts == 0
    assert row.fencing_token == 0
    assert row.lease_expires_at == nil
  end
end
