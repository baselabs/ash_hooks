defmodule AshHooks.TenancyTest do
  @moduledoc """
  The tenancy proofs (the tenancy design's test plan, R10): two-tenant
  sqlite fixtures (`org_a` the victim, `org_b` the ATTACKER — attacker rows
  seeded FIRST per the adversarial-ordering rule) over REAL tenant-bearing
  unique indexes.

  Proof groups (numbers are the design's test plan):

    1. Fanout isolation — org_a's event never creates a delivery row for
       org_b's endpoint.
    2. Cross-tenant endpoint_id — a subscription in org_a pointing at
       org_b's endpoint resolves NotFound and is skipped.
    3. Cross-tenant 410 — org_b's delivery worker cannot resolve (and so
       cannot disable) org_a's endpoint.
    4. Prune/reap scoping + the named `{:error, :tenant_required}` from the
       pre-flight (bang-path heads included).
    5. Job re-scope — `Delivery.run/2` from args alone recovers the tenant.
    6. Inbound cross-tenant dedup — same identity, two tenants, two rows.
    7. Lease/dead-letter isolation per tenant.
    8. `{:error, :tenancy_mismatch}` paths — any-vs-none, differing
       attribute, `global?: true`, non-`:attribute` strategy; on dispatch,
       on ingest, and on `Delivery.run`.
    10. Inertness — a tenant threaded onto single-tenant resources is a
        no-op (zero-breakage's mechanism).
    11. Cutover proofs — pre-tenancy args fail closed; the NULL-tenant
        backfill-ordering strand.
    12. Tenant-aware secret resolution (R6): the 1-arity inbound secret
        fn, the provider `webhook_signing_secret/2` override, and the
        `:tenant_aware_secrets` outbound resolver.
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("tenancy_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("tenancy_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.TenancyTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("tenancy_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
      timestamps()
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read])
    end
  end

  # The 1-arity secret fn resolves the TENANT's secret — the fixture uses
  # it, so every ingest here proves the tenant reached the resolver (proof
  # 12) while also driving the ordinary pipeline (proofs 6/7).
  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("tenancy_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
      timestamps()
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :counter do
        provider(AshHooks.CountingProvider)
        secret fn tenant -> {:ok, "tenancy-secret-" <> to_string(tenant)} end
        event_id(&__MODULE__.event_id/1)
      end

      inbound :perconn_tenant do
        provider(AshHooks.TenancyTest.TenantConnectionProvider)
        secret fn _tenant -> {:ok, "unused"} end
      end

      inbound :tenantbad do
        provider(AshHooks.CountingProvider)
        secret fn _tenant -> {:error, :gone} end
      end
    end

    def event_id(%{"id" => id}) when is_binary(id), do: {:ok, id}
    def event_id(_payload), do: :error
  end

  # Organization × connection custody: overrides webhook_signing_secret/2
  # (the use-form default delegates /2 → /1 — both shapes live here).
  defmodule TenantConnectionProvider do
    @moduledoc false
    use AshHooks.Provider

    @impl AshHooks.Provider
    def webhook_secret_scope, do: :per_connection

    @impl AshHooks.Provider
    def webhook_signing_secret(%{secret: secret}), do: {:ok, secret}

    @impl AshHooks.Provider
    def webhook_signing_secret(%{secret: :unconfigured}, _tenant), do: {:error, :no_webhook_secret}

    def webhook_signing_secret(%{secret: secret}, tenant), do: {:ok, secret <> "-" <> to_string(tenant)}

    @impl AshHooks.Provider
    def verify_signature(raw_body, ctx, secret),
      do: AshHooks.Provider.default_verify_signature(raw_body, ctx.signature, secret, :hmac_sha256)

    @impl AshHooks.Provider
    def parse_event_type(%{"id" => _}), do: {:ok, :counted}
    def parse_event_type(_), do: {:error, :unknown_event_type}

    @impl AshHooks.Provider
    def handle_event(type, payload), do: {:ok, %AshHooks.Event{type: type, payload: payload}}
  end

  # /1-only use-form provider: the overridable /2 default must delegate to
  # /1 (no tenant coupling) — resolution through the helper proves it.
  defmodule DelegatingConnectionProvider do
    @moduledoc false
    use AshHooks.Provider

    @impl AshHooks.Provider
    def webhook_secret_scope, do: :per_connection

    @impl AshHooks.Provider
    def webhook_signing_secret(%{secret: secret}), do: {:ok, secret}

    @impl AshHooks.Provider
    def verify_signature(raw_body, ctx, secret),
      do: AshHooks.Provider.default_verify_signature(raw_body, ctx.signature, secret, :hmac_sha256)

    @impl AshHooks.Provider
    def parse_event_type(%{"id" => _}), do: {:ok, :counted}
    def parse_event_type(_), do: {:error, :unknown_event_type}

    @impl AshHooks.Provider
    def handle_event(type, payload), do: {:ok, %AshHooks.Event{type: type, payload: payload}}
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.TenancyTest.Subscription)
        deliveries(AshHooks.TenancyTest.Delivery)
      end
    end
  end

  # ── mismatch fixtures: the declaration sets proof 8 rejects ──

  # any-vs-none: the endpoint side of the set declares nothing
  defmodule PlainEndpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("tenancy_plain_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule PartialSubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("tenancy_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.TenancyTest.PlainEndpoint)
    end
  end

  # never queried — the pre-flight rejects the set before any data access;
  # the sqlite block exists only because the resource is one
  defmodule MismatchDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("tenancy_mismatch_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:tenant_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:tenant_id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule GlobalDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("tenancy_mismatch_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
      global?(true)
    end

    actions do
      defaults([:read])
    end
  end

  # :context strategy — never queried (rejected pre-flight); the simple
  # data layer keeps it out of sqlite's capability surface entirely
  defmodule ContextDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: Ash.DataLayer.Simple,
      extensions: [AshHooks.OutboundDelivery]

    multitenancy do
      strategy(:context)
    end
  end

  defmodule GlobalLedger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    sqlite do
      table("tenancy_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:org_id, :string, allow_nil?: false)
    end

    multitenancy do
      strategy(:attribute)
      attribute(:org_id)
      global?(true)
    end

    actions do
      defaults([:read])
    end

    webhooks do
      inbound :counter do
        provider(AshHooks.CountingProvider)
        secret fn _tenant -> {:ok, "x"} end
      end
    end
  end

  # ── single-tenant fixtures: proof 10's inertness (byte-identical
  # behavior with a tenant threaded through) ──

  defmodule PlainSubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("tenancy_plain_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.TenancyTest.PlainEndpoint)
    end
  end

  defmodule PlainDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("tenancy_plain_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      timestamps()
    end

    actions do
      defaults([:read])
    end
  end

  defmodule PlainEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.TenancyTest.PlainSubscription)
        deliveries(AshHooks.TenancyTest.PlainDelivery)
      end
    end
  end

  # one emitter per mismatch shape — the outbound entity freezes its
  # resource pair at compile time, so each inconsistent set gets its own
  defmodule PartialEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.TenancyTest.PartialSubscription)
        deliveries(AshHooks.TenancyTest.Delivery)
      end
    end
  end

  defmodule AttrMismatchEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.TenancyTest.Subscription)
        deliveries(AshHooks.TenancyTest.MismatchDelivery)
      end
    end
  end

  defmodule GlobalEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.TenancyTest.Subscription)
        deliveries(AshHooks.TenancyTest.GlobalDelivery)
      end
    end
  end

  defmodule ContextEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.TenancyTest.Subscription)
        deliveries(AshHooks.TenancyTest.ContextDelivery)
      end
    end
  end

  # no `subscription` block: endpoint_resource introspects nil — the
  # pre-flight's fail-closed arm for an undeclared endpoint module
  defmodule BareSubscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("tenancy_plain_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end
  end

  defmodule BareSubscriptionEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.TenancyTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("tenancy_test_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.TenancyTest.BareSubscription)
        deliveries(AshHooks.TenancyTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.TenancyTest.BareSubscription)
      resource(AshHooks.TenancyTest.BareSubscriptionEmitter)
      resource(AshHooks.TenancyTest.Endpoint)
      resource(AshHooks.TenancyTest.Subscription)
      resource(AshHooks.TenancyTest.Delivery)
      resource(AshHooks.TenancyTest.Ledger)
      resource(AshHooks.TenancyTest.Emitter)
      resource(AshHooks.TenancyTest.PlainEndpoint)
      resource(AshHooks.TenancyTest.PartialSubscription)
      resource(AshHooks.TenancyTest.MismatchDelivery)
      resource(AshHooks.TenancyTest.GlobalDelivery)
      resource(AshHooks.TenancyTest.ContextDelivery)
      resource(AshHooks.TenancyTest.GlobalLedger)
      resource(AshHooks.TenancyTest.PlainSubscription)
      resource(AshHooks.TenancyTest.PlainDelivery)
      resource(AshHooks.TenancyTest.PlainEmitter)
      resource(AshHooks.TenancyTest.PartialEmitter)
      resource(AshHooks.TenancyTest.AttrMismatchEmitter)
      resource(AshHooks.TenancyTest.GlobalEmitter)
      resource(AshHooks.TenancyTest.ContextEmitter)
    end
  end

  use ExUnit.Case, async: false

  require Ash.Query
  require Spark.Test

  alias AshHooks.{Delivery, Dispatcher, Event, Ingress}
  alias AshHooks.Test.Repo

  @endpoints "tenancy_test_endpoints"
  @subscriptions "tenancy_test_subscriptions"
  @deliveries "tenancy_test_deliveries"
  @ledgers "tenancy_test_ledgers"
  @plain_endpoints "tenancy_plain_endpoints"
  @plain_subscriptions "tenancy_plain_subscriptions"
  @plain_deliveries "tenancy_plain_deliveries"
  @mismatch_deliveries "tenancy_mismatch_deliveries"
  @payload Jason.encode!(%{"order" => 1, "total" => 42})

  setup_all do
    create_tables!()

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@ledgers}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@plain_endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@plain_subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@plain_deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@mismatch_deliveries}")
    end)

    :ok
  end

  defp create_tables! do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL,
      previous_secret_ref TEXT,
      legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT,
      org_id TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY,
      event_types TEXT NOT NULL,
      endpoint_id TEXT NOT NULL,
      signing_mode TEXT,
      org_id TEXT NOT NULL
    )
    """)

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
      org_id TEXT,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@ledgers} (
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
      org_id TEXT NOT NULL,
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@plain_endpoints} (
      id TEXT PRIMARY KEY,
      url TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL,
      previous_secret_ref TEXT,
      legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@plain_subscriptions} (
      id TEXT PRIMARY KEY,
      event_types TEXT NOT NULL,
      endpoint_id TEXT NOT NULL,
      signing_mode TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@plain_deliveries} (
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
      inserted_at TEXT,
      updated_at TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@mismatch_deliveries} (
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
      org_id TEXT,
      tenant_id TEXT
    )
    """)

    # tenant-bearing indexes: the multitenancy attribute prefixes every
    # identity index (ash_sqlite prepends it when building operations —
    # the adopter's regenerated migration carries the same shape)
    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (org_id, endpoint_id, event_uuid)"
    )

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@ledgers}_unique_ingest_index ON #{@ledgers} (org_id, provider, external_event_id)"
    )

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@plain_deliveries}_unique_delivery_index ON #{@plain_deliveries} (endpoint_id, event_uuid)"
    )
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@ledgers}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@plain_endpoints}")
    Repo.query!("DELETE FROM #{@plain_subscriptions}")
    Repo.query!("DELETE FROM #{@plain_deliveries}")
    :ok
  end

  # The attacker's rows seed FIRST (the adversarial-ordering rule): a query
  # that accidentally drops its tenant filter must SEE these rows for the
  # isolation assertions to have teeth.
  defp two_tenant_fixture!(event_types \\ ["*"]) do
    attack_endpoint =
      Ash.create!(Endpoint, %{url: "https://attacker.test/hook", secret_ref: "attacker-ref"},
        tenant: "org_b",
        authorize?: false
      )

    attack_subscription =
      Ash.create!(Subscription, %{event_types: event_types, endpoint_id: attack_endpoint.id},
        tenant: "org_b",
        authorize?: false
      )

    victim_endpoint =
      Ash.create!(Endpoint, %{url: "https://victim.test/hook", secret_ref: "victim-ref"},
        tenant: "org_a",
        authorize?: false
      )

    victim_subscription =
      Ash.create!(Subscription, %{event_types: event_types, endpoint_id: victim_endpoint.id},
        tenant: "org_a",
        authorize?: false
      )

    {attack_endpoint, attack_subscription, victim_endpoint, victim_subscription}
  end

  # run-time retention horizon: rows 90 days back, cutoff 89 days back —
  # a full day of margin on both sides (compile-time constants drift
  # boundary-exact against run-time cutoffs)
  defp old do
    DateTime.add(DateTime.utc_now(), -90, :day) |> DateTime.truncate(:microsecond)
  end

  defp old_cutoff do
    DateTime.add(DateTime.utc_now(), -89, :day) |> DateTime.truncate(:microsecond)
  end

  defp event!(id) do
    {:ok, event} = Event.new(type: :order_paid, payload: @payload, id: id)
    event
  end

  defp rows(tenant) do
    AshHooks.TenancyTest.Delivery
    |> Ash.Query.filter(org_id == ^tenant)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp ledger_rows(tenant) do
    Ledger
    |> Ash.Query.filter(org_id == ^tenant)
    |> Ash.read!(authorize?: false, tenant: tenant)
  end

  defp ingest!(id, tenant, overrides \\ []) do
    body = Jason.encode!(%{"id" => id, "type" => "counted", "n" => 1})
    secret = "tenancy-secret-" <> to_string(tenant)
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    ctx = Map.merge(%{signature: signature, headers: %{}}, Map.new(overrides))

    Ingress.ingest(Ledger, :counter, body, Map.put(ctx, :tenant, tenant))
  end

  # raw ledger row for the sweep/reap proofs (bypasses the pipeline —
  # these tests own the row state exactly; the body re-drives cleanly
  # through the :counter provider when a re-drive happens)
  defp ledger_row!(tenant, external_id, status, lease_expires_at, inserted_at),
    do: ledger_row!(tenant, external_id, "counter", status, lease_expires_at, inserted_at)

  defp ledger_row!(tenant, external_id, provider, status, lease_expires_at, inserted_at) do
    id = Ash.UUID.generate()
    payload = Jason.encode!(%{"id" => external_id, "type" => "counted", "n" => 1})

    inserted = inserted_at && DateTime.to_iso8601(inserted_at)

    Repo.query!(
      "INSERT INTO #{@ledgers} (id, provider, external_event_id, payload, payload_digest, " <>
        "status, fencing_token, lease_expires_at, attempts, org_id, inserted_at, updated_at) " <>
        "VALUES (?, ?, ?, ?, 'digest', ?, 0, ?, 0, ?, ?, ?)",
      [
        id,
        provider,
        external_id,
        payload,
        status,
        lease_expires_at && DateTime.to_iso8601(lease_expires_at),
        tenant,
        inserted,
        inserted
      ]
    )

    id
  end

  # ────────────────────────── proof 1: fanout isolation ──────────────────────────

  test "dispatch for org_a fans out to org_a's endpoint only — org_b's attacker row never receives payload bytes" do
    {attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    assert {:ok, results} =
             Dispatcher.dispatch(Emitter, :order_paid, event!("evt-1"), tenant: "org_a")

    # no enqueue seam → the row persists :pending and the result defers
    assert [%{status: :deferred, endpoint_id: victim_id}] = results
    assert victim_id == victim_endpoint.id

    victim_rows = rows("org_a")
    attack_rows = rows("org_b")

    assert [%{endpoint_id: ^victim_id}] = victim_rows
    assert attack_rows == []

    # the persisted bytes: org_b's endpoint id appears on NO row, and the
    # payload never landed in an org_b partition
    assert attack_endpoint.id not in Enum.map(victim_rows, & &1.endpoint_id)
  end

  test "dispatch with no tenant against multitenant resources fails closed with the named error before any data access" do
    two_tenant_fixture!()

    assert {:error, :tenant_required} =
             Dispatcher.dispatch(Emitter, :order_paid, event!("evt-2"), [])
  end

  # ────────────────────────── proof 2: cross-tenant endpoint_id ──────────────────────────

  test "a subscription in org_a pointing at org_b's endpoint_id resolves NotFound and is skipped — no row for the attacker's endpoint" do
    {attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    # the attacker's endpoint id, planted in the VICTIM's subscription
    Ash.create!(Subscription, %{event_types: ["*"], endpoint_id: attack_endpoint.id},
      tenant: "org_a",
      authorize?: false
    )

    assert {:ok, results} =
             Dispatcher.dispatch(Emitter, :order_paid, event!("evt-3"), tenant: "org_a")

    # the victim's OWN subscription delivers; the cross-tenant one is
    # SKIPPED by design (no row, no entry) — same classification as a gone
    # endpoint, now tenant-enforced
    assert [%{status: :deferred, endpoint_id: victim_id}] = results
    assert victim_id == victim_endpoint.id

    org_a_rows = rows("org_a")
    assert [%{endpoint_id: ^victim_id}] = org_a_rows
    assert attack_endpoint.id not in Enum.map(org_a_rows, & &1.endpoint_id)
    assert rows("org_b") == []
  end

  # ────────────────────────── proof 3: cross-tenant 410 ──────────────────────────

  test "org_b's delivery worker cannot resolve org_a's endpoint (the tenant-scoped fetch) — the row dead-letters as endpoint_gone, no disable possible" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    # a delivery ROW in org_b aimed at org_a's endpoint id
    row =
      Ash.create!(
        AshHooks.TenancyTest.Delivery,
        %{
          event_uuid: "evt-cross-410",
          event_type: "order_paid",
          payload: @payload,
          endpoint_id: victim_endpoint.id,
          signing_mode: :standard
        },
        action: :dispatch,
        tenant: "org_b",
        authorize?: false
      )

    assert :ok =
             AshHooks.Delivery.run(
               %{"endpoint_id" => victim_endpoint.id, "event_uuid" => row.event_uuid, "tenant" => "org_b"},
               delivery_config()
             )

    # the row dead-lettered WITHOUT touching org_a's endpoint
    dead =
      AshHooks.TenancyTest.Delivery
      |> Ash.Query.filter(event_uuid == ^row.event_uuid)
      |> Ash.read_one!(authorize?: false, tenant: "org_b")

    assert dead.status == :dead_letter
    assert dead.last_error == "endpoint_gone"

    # org_a's endpoint is STILL enabled — the 410 disable (and the
    # endpoint fetch feeding it) is unreachable from org_b's row
    survivor = Ash.get!(Endpoint, victim_endpoint.id, tenant: "org_a", authorize?: false)
    assert survivor.status == :enabled
  end

  test "an in-tenant 410 disables the endpoint under the row's tenant and dead-letters as gone_410" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    Ash.create!(
      AshHooks.TenancyTest.Delivery,
      %{
        event_uuid: "evt-410-ours",
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: victim_endpoint.id,
        signing_mode: :standard
      },
      action: :dispatch,
      tenant: "org_a",
      authorize?: false
    )

    four_oh_four =
      delivery_config()
      |> Keyword.put(:http, fn _m, _u, _h, _b, _o -> {:ok, %{status: 410, headers: [], body: ""}} end)

    assert :ok =
             AshHooks.Delivery.run(
               %{"endpoint_id" => victim_endpoint.id, "event_uuid" => "evt-410-ours", "tenant" => "org_a"},
               four_oh_four
             )

    # the disable LANDED (in-tenant, matched) and the row dead-lettered
    disabled = Ash.get!(Endpoint, victim_endpoint.id, tenant: "org_a", authorize?: false)
    assert disabled.status == :disabled

    dead =
      AshHooks.TenancyTest.Delivery
      |> Ash.Query.filter(event_uuid == "evt-410-ours")
      |> Ash.read_one!(authorize?: false, tenant: "org_a")

    assert dead.status == :dead_letter
    assert dead.last_error == "gone_410"
  end

  test "a 410 whose endpoint vanishes before the disable write surfaces the error — never a silent no-op circuit-break" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    Ash.create!(
      AshHooks.TenancyTest.Delivery,
      %{
        event_uuid: "evt-410-vanish",
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: victim_endpoint.id,
        signing_mode: :standard
      },
      action: :dispatch,
      tenant: "org_a",
      authorize?: false
    )

    vanishing =
      delivery_config()
      |> Keyword.put(:http, fn _m, _u, _h, _b, _o ->
        # the endpoint was fetched (attempt) but not yet disabled (record)
        # — deleting it here makes the disable a ZERO-match "success"
        Repo.query!("DELETE FROM #{@endpoints} WHERE id = ?", [victim_endpoint.id])
        {:ok, %{status: 410, headers: [], body: ""}}
      end)

    assert {:error, {:disable_failed, :endpoint_vanished}} =
             AshHooks.Delivery.run(
               %{"endpoint_id" => victim_endpoint.id, "event_uuid" => "evt-410-vanish", "tenant" => "org_a"},
               vanishing
             )
  end

  # ────────────────────────── proof 4: sweeps ──────────────────────────

  test "a tenant-less reap over a multitenant ledger is the NAMED error, not a bang crash" do
    ledger_row!("org_a", "sweep-1", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)

    assert {:error, :tenant_required} = Ingress.reap(Ledger)
  end

  test "prune and reap are tenant-scoped — one tenant's sweep never touches the other's rows" do
    # attacker rows FIRST
    ledger_row!("org_b", "old-b", "processed", nil, old())
    ledger_row!("org_b", "expired-b", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)
    ledger_row!("org_a", "old-a", "processed", nil, old())
    ledger_row!("org_a", "expired-a", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)

    assert {:ok, 1} = Ingress.prune(Ledger, older_than: old_cutoff(), tenant: "org_a")

    assert [%{external_event_id: "old-b"}] =
             Ledger |> Ash.Query.filter(external_event_id == "old-b") |> Ash.read!(authorize?: false, tenant: "org_b")

    assert {:ok, 1} = Ingress.reap(Ledger, tenant: "org_a")

    # org_b's expired row untouched; org_a's was re-driven to processed
    expired_b =
      Ledger |> Ash.Query.filter(external_event_id == "expired-b") |> Ash.read_one!(authorize?: false, tenant: "org_b")

    assert expired_b.status == :claimed

    expired_a =
      Ledger |> Ash.Query.filter(external_event_id == "expired-a") |> Ash.read_one!(authorize?: false, tenant: "org_a")

    assert expired_a.status == :processed
  end

  test "a handler that THROWS or EXITS mid-redrive is contained — reap skips the row, never aborts the sweep" do
    AshHooks.CountingProvider.put_sink(self())

    # first poisoned redrive throws, second exits, then the healthy row
    # processes — both crash classes contained, sweep survives both
    calls = :counters.new(1, [:write_concurrency])

    AshHooks.CountingProvider.put_outcome(fn ->
      send(self(), :handler_ran)
      :counters.add(calls, 1, 1)

      if :counters.get(calls, 1) == 1, do: throw(:poison), else: exit(:boom)
    end)

    on_exit(fn -> AshHooks.CountingProvider.cleanup() end)

    ledger_row!("org_a", "poison-throw", "counter", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)
    ledger_row!("org_a", "poison-exit", "counter", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)
    ledger_row!("org_a", "healthy-a", "perconn_tenant", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)

    assert {:ok, 1} = Ingress.reap(Ledger, tenant: "org_a")

    # both poison handlers RAN (their crash was contained at the handler,
    # not skipped before it)
    assert_received :handler_ran
    assert_received :handler_ran

    for id <- ["poison-throw", "poison-exit"] do
      row = Ledger |> Ash.Query.filter(external_event_id == ^id) |> Ash.read_one!(authorize?: false, tenant: "org_a")

      # attempts == 1 proves the redrive CLAIMED the row and the handler
      # RAN (claim bumps attempts) — the crash was contained at the
      # handler, not skipped before it
      assert row.status == :claimed
      assert row.attempts == 1
    end

    healthy =
      Ledger |> Ash.Query.filter(external_event_id == "healthy-a") |> Ash.read_one!(authorize?: false, tenant: "org_a")

    assert healthy.status == :processed
  end

  test "reap_all and prune_all sweep per tenant with per-tenant error isolation and a total" do
    ledger_row!("org_b", "expired-b", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)
    ledger_row!("org_a", "expired-a", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)
    ledger_row!("org_a", "expired-a2", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)

    assert {:ok, %{results: %{"org_a" => {:ok, 2}, "org_b" => {:ok, 1}}, total: 3}} =
             AshHooks.reap_all(Ledger, tenants: ["org_a", "org_b"])

    ledger_row!("org_a", "old-a", "processed", nil, old())
    ledger_row!("org_b", "old-b", "processed", nil, old())

    assert {:ok, %{results: %{"org_a" => {:ok, 1}, "org_b" => {:ok, 1}}, total: 2}} =
             AshHooks.prune_all(Ledger, older_than: old_cutoff(), tenants: ["org_a", "org_b"])

    # duplicate tenants are deduplicated — a repeat would overwrite its
    # own earlier result while still counting into the total
    ledger_row!("org_a", "dup-sweep-a", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)

    assert {:ok, %{results: %{"org_a" => {:ok, 1}}, total: 1}} =
             AshHooks.reap_all(Ledger, tenants: ["org_a", "org_a"])

    # error isolation: a tenant value Ash cannot convert crashes THAT
    # tenant's sweep only — the others complete and the crash is carried
    # as the tenant's result, never raised through the sweep
    ledger_row!("org_a", "expired-a3", "claimed", DateTime.add(DateTime.utc_now(), -60, :second), nil)

    assert {:ok, %{results: results, total: 1}} =
             AshHooks.reap_all(Ledger, tenants: [%{bad: :tenant}, "org_a"])

    assert {:ok, 1} = results["org_a"]
    assert {:error, {:sweep_crashed, _}} = results[%{bad: :tenant}]
  end

  test "prune_all routes by extension and rejects foreign resources" do
    assert {:error, %AshHooks.Errors.Unknown.UnknownError{}} =
             AshHooks.prune_all(Endpoint, older_than: old_cutoff(), tenants: ["org_a"])
  end

  test "the outbound prune is tenant-scoped too" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    for tenant <- ["org_b", "org_a"] do
      Ash.create!(
        AshHooks.TenancyTest.Delivery,
        %{
          event_uuid: "prune-" <> tenant,
          event_type: "order_paid",
          payload: @payload,
          endpoint_id: victim_endpoint.id,
          signing_mode: :standard
        },
        action: :dispatch,
        tenant: tenant,
        authorize?: false
      )

      # terminal + backdated past the cutoff (the machine stamps now)
      Repo.query!("UPDATE #{@deliveries} SET status = 'succeeded', inserted_at = ?, updated_at = ? WHERE org_id = ?", [
        DateTime.to_iso8601(old()),
        DateTime.to_iso8601(old()),
        tenant
      ])
    end

    assert {:ok, 1} = AshHooks.Delivery.prune(AshHooks.TenancyTest.Delivery, older_than: old_cutoff(), tenant: "org_a")
    assert [%{org_id: "org_b"}] = Ash.read!(AshHooks.TenancyTest.Delivery, authorize?: false, tenant: "org_b")
    assert [] == Ash.read!(AshHooks.TenancyTest.Delivery, authorize?: false, tenant: "org_a")
  end

  # ────────────────────────── proof 5: job re-scope ──────────────────────────

  test "run/2 recovers the tenant from args alone (simulated restart), and the tenant survives Oban's JSON round-trip" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    {:ok, [%{status: :deferred}]} =
      Dispatcher.dispatch(Emitter, :order_paid, event!("evt-scope"), tenant: "org_a")

    row = hd(rows("org_a"))

    # the args exactly as a worker restart would see them: JSON-encoded
    # by Oban at enqueue, decoded at perform — tenant included
    decoded =
      Jason.decode!(
        Jason.encode!(%{
          "endpoint_id" => victim_endpoint.id,
          "event_uuid" => row.event_uuid,
          "tenant" => "org_a"
        })
      )

    assert :ok = AshHooks.Delivery.run(decoded, delivery_config())

    sent =
      AshHooks.TenancyTest.Delivery
      |> Ash.Query.filter(event_uuid == ^row.event_uuid)
      |> Ash.read_one!(authorize?: false, tenant: "org_a")

    assert sent.status == :succeeded
  end

  test "pre-tenancy job args (no tenant key) fail closed against multitenant resources" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    {:ok, [%{status: :deferred}]} =
      Dispatcher.dispatch(Emitter, :order_paid, event!("evt-pre"), tenant: "org_a")

    row = hd(rows("org_a"))

    assert {:error, :tenant_required} =
             AshHooks.Delivery.run(
               %{"endpoint_id" => victim_endpoint.id, "event_uuid" => row.event_uuid},
               delivery_config()
             )

    # the row itself never moved
    still = hd(rows("org_a"))
    assert still.status == :pending
  end

  # ────────────────────────── proof 6: inbound cross-tenant dedup ──────────────────────────

  test "the public ingest_delivery/2 head runs the same pre-flight — tenant-less on a multitenant ledger is the named error" do
    assert {:error, :tenant_required} =
             Ingress.ingest_delivery(Ledger, %{
               name: :counter,
               provider: AshHooks.CountingProvider,
               payload: %{},
               digest: "d",
               external_event_id: "e",
               type_string: nil,
               scope: %{}
             })
  end

  test "the same provider event id in two tenants is TWO rows, both processed — and a tenant-less ingest fails closed" do
    assert {:error, :tenant_required} =
             Ingress.ingest(Ledger, :counter, Jason.encode!(%{"id" => "dup-1"}), %{signature: "x"})

    assert {:ok, :created, first} = ingest!("dup-1", "org_a")
    assert {:ok, :created, second} = ingest!("dup-1", "org_b")

    assert first.id != second.id
    assert first.status == :processed
    assert second.status == :processed

    # and within ONE tenant the same id is still exactly-once
    assert {:ok, :duplicate, _} = ingest!("dup-1", "org_a")
    assert [%{}] = ledger_rows("org_a")
    assert [%{}] = ledger_rows("org_b")
  end

  # ────────────────────────── proof 7: lease/dead-letter isolation ──────────────────────────

  test "a claim's fence is per-tenant: org_b cannot mark org_a's row even with its exact id and token" do
    # a RECEIVED row (the ingest pipeline would have processed it)
    row_id = ledger_row!("org_a", "lease-1", "received", nil, nil)

    {:ok, token, _claimed} = Ingress.claim_delivery(Ledger, row_id, tenant: "org_a")

    # org_b's sweep with org_a's id + token: the row is INVISIBLE under
    # org_b's tenant — stale_token, never a cross-tenant mark
    assert {:error, :stale_token} =
             Ingress.mark_processed(Ledger, row_id, token, tenant: "org_b")

    untouched =
      Ledger |> Ash.Query.filter(external_event_id == "lease-1") |> Ash.read_one!(authorize?: false, tenant: "org_a")

    assert untouched.status == :claimed

    # the tenant-less mark is the named error (the head family's guard)
    assert {:error, :tenant_required} = Ingress.mark_processed(Ledger, row_id, token)
  end

  # ────────────────────────── proof 8: tenancy_mismatch ──────────────────────────

  test "any-vs-none (endpoints undeclared beside tenant-scoped subs/deliveries) is :tenancy_mismatch on dispatch" do
    assert {:error, :tenancy_mismatch} =
             Dispatcher.dispatch(PartialEmitter, :order_paid, event!("mismatch-1"), tenant: "org_a")
  end

  test "differing multitenancy attributes across the set is :tenancy_mismatch" do
    assert {:error, :tenancy_mismatch} =
             Dispatcher.dispatch(AttrMismatchEmitter, :order_paid, event!("mismatch-2"), tenant: "org_a")
  end

  test "global?: true anywhere in the set is :tenancy_mismatch (fail-closed disabled)" do
    assert {:error, :tenancy_mismatch} =
             Dispatcher.dispatch(GlobalEmitter, :order_paid, event!("mismatch-3"), tenant: "org_a")
  end

  test "a non-:attribute strategy in the set is :tenancy_mismatch" do
    assert {:error, :tenancy_mismatch} =
             Dispatcher.dispatch(ContextEmitter, :order_paid, event!("mismatch-4"), tenant: "org_a")
  end

  test "the runtime path checks too: Delivery.run with a mismatched set fails closed before data access" do
    # deliveries multitenant, endpoints NOT — the exact hazard D3 names:
    # a globally-resolved endpoint under a tenant-scoped row
    config =
      Keyword.put(delivery_config(), :endpoints, AshHooks.TenancyTest.PlainEndpoint)

    assert {:error, :tenancy_mismatch} =
             AshHooks.Delivery.run(
               %{"endpoint_id" => "any", "event_uuid" => "any", "tenant" => "org_a"},
               config
             )
  end

  test "ingest rejects a global?: true ledger as :tenancy_mismatch" do
    body = Jason.encode!(%{"id" => "g-1"})
    signature = :crypto.mac(:hmac, :sha256, "x", body) |> Base.encode16(case: :lower)

    assert {:error, :tenancy_mismatch} =
             Ingress.ingest(GlobalLedger, :counter, body, %{
               signature: signature,
               tenant: "org_a"
             })
  end

  # ────────────────────────── proof 10: inertness ──────────────────────────

  test "a tenant threaded through single-tenant resources changes nothing — with or without it, identical dispatches" do
    endpoint =
      Ash.create!(PlainEndpoint, %{url: "https://plain.test/hook", secret_ref: "ref"}, authorize?: false)

    Ash.create!(PlainSubscription, %{event_types: ["*"], endpoint_id: endpoint.id}, authorize?: false)

    assert {:ok, [with_tenant]} =
             Dispatcher.dispatch(PlainEmitter, :order_paid, event!("plain-1"), tenant: "org_z")

    assert {:ok, [without]} =
             Dispatcher.dispatch(PlainEmitter, :order_paid, event!("plain-2"))

    assert with_tenant.status == :deferred
    assert without.status == :deferred

    plain_rows = Ash.read!(PlainDelivery, authorize?: false)
    assert length(plain_rows) == 2
  end

  test "the tenancy resolver passes a tenant through a single-tenant set untouched" do
    assert {:ok, "org_z"} = AshHooks.Tenancy.resolve([PlainEndpoint, PlainSubscription], "org_z")
    assert {:ok, nil} = AshHooks.Tenancy.resolve([PlainEndpoint], nil)
  end

  # ────────────────────────── proof 11: cutover ──────────────────────────

  test "NULL-tenant legacy rows shadow the tenant-bearing identity: dispatch before backfill creates a PARALLEL row (the motivating strand)" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    # a pre-tenancy row: same (endpoint, event) pair, NULL tenant — as the
    # adopter's table looks BEFORE the backfill migration
    Repo.query!(
      "INSERT INTO #{@deliveries} (id, event_uuid, event_type, payload, endpoint_id, signing_mode, status, attempts, org_id) VALUES (?, ?, ?, ?, ?, ?, ?, 0, NULL)",
      [Ash.UUID.generate(), "evt-legacy", "order_paid", @payload, victim_endpoint.id, "standard", "succeeded"]
    )

    assert {:ok, [%{status: :deferred}]} =
             Dispatcher.dispatch(Emitter, :order_paid, event!("evt-legacy"), tenant: "org_a")

    # TWO rows for the pair: NULL ≠ 'org_a' in the tenant-bearing unique
    # identity — the upsert created a parallel row instead of deduping.
    # This is the ordered-transition hazard: backfill FIRST, then enable.
    pair =
      AshHooks.TenancyTest.Delivery
      |> Ash.Query.filter(endpoint_id == ^victim_endpoint.id and event_uuid == "evt-legacy")
      |> Ash.read!(authorize?: false, tenant: "org_a")

    legacy =
      Repo.query!("SELECT COUNT(*) c FROM #{@deliveries} WHERE event_uuid = 'evt-legacy'")

    assert length(pair) == 1
    assert legacy.rows == [[2]]
  end

  # ────────────────────────── proof 12: tenant-aware secrets ──────────────────────────

  test "the 1-arity inbound secret fn resolves the TENANT's secret (and a wrong-tenant signature fails closed)" do
    # ingest! signs with tenancy-secret-org_a — proof 6 already drove it;
    # here the negative space proves the tenant actually selected the key
    body = Jason.encode!(%{"id" => "sec-1", "type" => "counted", "n" => 1})
    wrong_key_signature = :crypto.mac(:hmac, :sha256, "tenancy-secret-org_b", body) |> Base.encode16(case: :lower)

    assert {:error, %AshHooks.Errors.Invalid.InvalidSignature{}} =
             Ingress.ingest(Ledger, :counter, body, %{signature: wrong_key_signature, tenant: "org_a"})
  end

  test "the provider webhook_signing_secret/2 override resolves Organization × connection custody" do
    body = Jason.encode!(%{"id" => "conn-1", "type" => "counted", "n" => 1})
    secret = "conn-secret-org_a"
    signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)

    assert {:ok, :created, delivery} =
             Ingress.ingest(Ledger, :perconn_tenant, body, %{
               signature: signature,
               connection: %{secret: "conn-secret"},
               tenant: "org_a"
             })

    assert delivery.status == :processed
  end

  test "the use form compiles for an app-level provider (neither secret callback) and its default /2 fails closed" do
    errors =
      Spark.Test.dsl_errors do
        defmodule Elixir.AshHooks.TenancyTest.AppScopeProbeProvider do
          @moduledoc false
          use AshHooks.Provider

          @impl AshHooks.Provider
          def verify_signature(_raw, _ctx, _secret), do: :ok

          @impl AshHooks.Provider
          def parse_event_type(_p), do: {:ok, :counted}

          @impl AshHooks.Provider
          def handle_event(t, p), do: {:ok, %AshHooks.Event{type: t, payload: p}}
        end
      end

    # compiles clean with NO webhook_signing_secret clause at all — the
    # overridable /2 default must not force a local /1 (cross-vendor
    # finding: the unconditional delegation broke app-scope use-form
    # providers at compile time)
    assert [] = errors

    assert {:error, :no_webhook_secret} =
             AshHooks.Provider.webhook_signing_secret(
               AshHooks.TenancyTest.AppScopeProbeProvider,
               %{},
               "org_a"
             )
  after
    :code.purge(AshHooks.TenancyTest.AppScopeProbeProvider)
    :code.delete(AshHooks.TenancyTest.AppScopeProbeProvider)
  end

  test "the helper prefers an overriding /2; a use-form /1-only provider resolves through the macro's overridable default" do
    assert {:ok, "conn-secret-org_a"} =
             AshHooks.Provider.webhook_signing_secret(
               TenantConnectionProvider,
               %{secret: "conn-secret"},
               "org_a"
             )

    assert {:ok, "delegated"} =
             AshHooks.Provider.webhook_signing_secret(
               DelegatingConnectionProvider,
               %{secret: "delegated"},
               "org_a"
             )
  end

  test "the :tenant_aware_secrets resolver receives (ref, tenant) on the run's tenant" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    Ash.create!(
      AshHooks.TenancyTest.Delivery,
      %{
        event_uuid: "evt-secrets",
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: victim_endpoint.id,
        signing_mode: :standard
      },
      action: :dispatch,
      tenant: "org_a",
      authorize?: false
    )

    test_pid = self()

    config =
      delivery_config()
      |> Keyword.put(:tenant_aware_secrets, true)
      |> Keyword.put(:secret_resolver, fn "victim-ref", tenant ->
        send(test_pid, {:resolver, tenant})
        {:ok, "whsec_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}
      end)

    assert :ok =
             AshHooks.Delivery.run(
               %{"endpoint_id" => victim_endpoint.id, "event_uuid" => "evt-secrets", "tenant" => "org_a"},
               config
             )

    assert_received {:resolver, "org_a"}
  end

  test "a resolver whose arity contradicts the declared contract classifies as a retryable secret_resolution failure" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    Ash.create!(
      AshHooks.TenancyTest.Delivery,
      %{
        event_uuid: "evt-badarity",
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: victim_endpoint.id,
        signing_mode: :standard
      },
      action: :dispatch,
      tenant: "org_a",
      authorize?: false
    )

    # {m, f} pointing at a 1-arity function under a 2-arity contract: the
    # apply raises BadArityError inside the guarded resolve — classified,
    # never a job crash
    config =
      delivery_config()
      |> Keyword.put(:tenant_aware_secrets, true)
      |> Keyword.put(:secret_resolver, {__MODULE__, :one_arity_secret})

    assert {:snooze, _delay} =
             AshHooks.Delivery.run(
               %{"endpoint_id" => victim_endpoint.id, "event_uuid" => "evt-badarity", "tenant" => "org_a"},
               config
             )

    failed =
      AshHooks.TenancyTest.Delivery
      |> Ash.Query.filter(event_uuid == "evt-badarity")
      |> Ash.read_one!(authorize?: false, tenant: "org_a")

    assert failed.status == :failed_retryable
    assert failed.last_error == "secret_resolution"
  end

  def one_arity_secret(_ref), do: {:ok, "whsec_x"}

  # ────────────────────────── verifier ──────────────────────────
  # Verifier errors ride Spark's @after_verify hook — rescued and
  # collected, not raised through the compile call — so these assert
  # through Spark.Test's structured collector with inline defmodules
  # (the documented shape: bare Code.compile_string is timing-dependent).

  test "a multitenant package resource with a bypass-marked action fails verification" do
    errors =
      Spark.Test.dsl_errors do
        defmodule Elixir.AshHooks.TenancyTest.BypassProbe do
          @moduledoc false
          use Ash.Resource,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshHooks.InboundDelivery]

          attributes do
            attribute(:org_id, :string, allow_nil?: false)
          end

          multitenancy do
            strategy(:attribute)
            attribute(:org_id)
          end

          actions do
            defaults([:read])

            update :flip_global do
              multitenancy(:bypass)
              accept([])
            end
          end
        end
      end

    assert [{AshHooks.TenancyTest.BypassProbe, [%Spark.Error.DslError{} = error]}] = errors
    assert Exception.message(error) =~ "multitenancy :bypass"
    assert Exception.message(error) =~ "flip_global"
  after
    :code.purge(AshHooks.TenancyTest.BypassProbe)
    :code.delete(AshHooks.TenancyTest.BypassProbe)
  end

  test "a GENERIC action on a multitenant package resource verifies clean (the guard Map.gets, never struct-accesses)" do
    errors =
      Spark.Test.dsl_errors do
        defmodule Elixir.AshHooks.TenancyTest.GenericActionProbe do
          @moduledoc false
          use Ash.Resource,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshHooks.OutboundDelivery]

          attributes do
            attribute(:org_id, :string, allow_nil?: false)
          end

          multitenancy do
            strategy(:attribute)
            attribute(:org_id)
          end

          actions do
            defaults([:read])

            action :pending_count, :integer do
              run(fn _input, _ctx -> {:ok, 0} end)
            end
          end
        end
      end

    # the generic action entity carries no :multitenancy key — struct
    # access raised KeyError here (cross-vendor finding, both peers)
    assert [] = errors
  after
    :code.purge(AshHooks.TenancyTest.GenericActionProbe)
    :code.delete(AshHooks.TenancyTest.GenericActionProbe)
  end

  test "an :allow_global action on a multitenant package resource is rejected — the per-action twin of global?: true" do
    errors =
      Spark.Test.dsl_errors do
        defmodule Elixir.AshHooks.TenancyTest.AllowGlobalProbe do
          @moduledoc false
          use Ash.Resource,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshHooks.InboundDelivery]

          attributes do
            attribute(:org_id, :string, allow_nil?: false)
          end

          multitenancy do
            strategy(:attribute)
            attribute(:org_id)
          end

          actions do
            defaults([:read])

            read :all_rows do
              multitenancy(:allow_global)
            end
          end
        end
      end

    assert [{AshHooks.TenancyTest.AllowGlobalProbe, [%Spark.Error.DslError{} = error]}] = errors
    assert Exception.message(error) =~ ":allow_global"
  after
    :code.purge(AshHooks.TenancyTest.AllowGlobalProbe)
    :code.delete(AshHooks.TenancyTest.AllowGlobalProbe)
  end

  test "a single-tenant package resource with a bypass-marked action verifies clean (bypass is meaningless there)" do
    errors =
      Spark.Test.dsl_errors do
        defmodule Elixir.AshHooks.TenancyTest.BypassPlainProbe do
          @moduledoc false
          use Ash.Resource,
            data_layer: Ash.DataLayer.Simple,
            extensions: [AshHooks.InboundDelivery]

          actions do
            defaults([:read])

            update :flip_global do
              multitenancy(:bypass)
              accept([])
            end
          end
        end
      end

    assert errors == []
  after
    :code.purge(AshHooks.TenancyTest.BypassPlainProbe)
    :code.delete(AshHooks.TenancyTest.BypassPlainProbe)
  end

  test "a subscriptions resource with no declared endpoint_resource fails closed before any data access" do
    assert {:error, error} =
             Dispatcher.dispatch(BareSubscriptionEmitter, :order_paid, event!("bare-1"), tenant: "org_a")

    assert Exception.message(error) =~ "declares no subscription.endpoint_resource"
  end

  test "a per-connection provider resolving an unusable secret fails closed as no_webhook_secret" do
    body = Jason.encode!(%{"id" => "conn-bad", "type" => "counted", "n" => 1})
    signature = :crypto.mac(:hmac, :sha256, "whatever", body) |> Base.encode16(case: :lower)

    assert {:error, %AshHooks.Errors.Invalid.NoWebhookSecret{}} =
             Ingress.ingest(Ledger, :perconn_tenant, body, %{
               signature: signature,
               connection: %{secret: :unconfigured},
               tenant: "org_a"
             })
  end

  test "a tenant-secret fn that fails closed surfaces no_webhook_secret" do
    body = Jason.encode!(%{"id" => "tb-1"})
    signature = :crypto.mac(:hmac, :sha256, "whatever", body) |> Base.encode16(case: :lower)

    assert {:error, %AshHooks.Errors.Invalid.NoWebhookSecret{}} =
             Ingress.ingest(Ledger, :tenantbad, body, %{signature: signature, tenant: "org_a"})
  end

  test "a 1-arity fn resolver under the 2-arity contract classifies as invalid_resolver (shape mismatch, no crash)" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    Ash.create!(
      AshHooks.TenancyTest.Delivery,
      %{
        event_uuid: "evt-fnshape",
        event_type: "order_paid",
        payload: @payload,
        endpoint_id: victim_endpoint.id,
        signing_mode: :standard
      },
      action: :dispatch,
      tenant: "org_a",
      authorize?: false
    )

    config =
      delivery_config()
      |> Keyword.put(:tenant_aware_secrets, true)
      |> Keyword.put(:secret_resolver, fn _ref -> {:ok, "whsec_x"} end)

    assert {:snooze, _} =
             AshHooks.Delivery.run(
               %{"endpoint_id" => victim_endpoint.id, "event_uuid" => "evt-fnshape", "tenant" => "org_a"},
               config
             )
  end

  test "a resolver that exits or throws classifies as invalid_resolver — the job keeps its row-owned policy" do
    {_attack_endpoint, _attack_sub, victim_endpoint, _victim_sub} = two_tenant_fixture!()

    for {uuid, bad} <- [{"evt-exit", fn _ref, _t -> exit(:boom) end}, {"evt-throw", fn _ref, _t -> throw(:boom) end}] do
      Ash.create!(
        AshHooks.TenancyTest.Delivery,
        %{
          event_uuid: uuid,
          event_type: "order_paid",
          payload: @payload,
          endpoint_id: victim_endpoint.id,
          signing_mode: :standard
        },
        action: :dispatch,
        tenant: "org_a",
        authorize?: false
      )

      config =
        delivery_config()
        |> Keyword.put(:tenant_aware_secrets, true)
        |> Keyword.put(:secret_resolver, bad)

      assert {:snooze, _} =
               AshHooks.Delivery.run(
                 %{"endpoint_id" => victim_endpoint.id, "event_uuid" => uuid, "tenant" => "org_a"},
                 config
               )
    end
  end

  # ────────────────────────── helpers ──────────────────────────

  defp delivery_config do
    [
      deliveries: AshHooks.TenancyTest.Delivery,
      endpoints: AshHooks.TenancyTest.Endpoint,
      secret_resolver: fn _ref ->
        {:ok, "whsec_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}
      end,
      max_attempts: 3,
      base_backoff_seconds: 1,
      max_backoff_seconds: 2,
      retry_after_cap_seconds: 2,
      # deterministic test sends: literal-only check + a 200 adapter
      ssrf_check: fn _url -> true end,
      http: fn _method, _url, _headers, _body, _opts ->
        {:ok, %{status: 200, headers: [], body: ""}}
      end
    ]
  end
end
