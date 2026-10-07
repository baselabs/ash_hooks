defmodule AshHooks.PkAcceptTest do
  @moduledoc """
  Consumer scenario (H2, the first-serious-consumer integration): a
  consumer declares a time-ordered `uuid_v7_primary_key` (non-writable by
  Ash's own definition — sirtify's webhook_delivery.ex:111 shape), and
  the injected `:dispatch`/`:ingest` accept lists carried `:id`, so
  Ash's ValidateAccept raised at compile on EXACTLY that shape —
  adopting the extensions required replacing the PK. The accept lists
  now carry `:id` only when the resource's PK is a writable `:id`
  (the package-injected default — byte-identical classification), and
  a non-writable-PK resource classifies created/duplicate by an
  identity pre-read instead (exact in every sequential case; under a
  true concurrent double-delivery the storage upsert, the inbound claim
  fence, and Oban's endpoint_id+event_uuid job uniqueness keep every
  effect exactly-once).
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("pk_accept_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("pk_accept_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.PkAcceptTest.Endpoint)
    end
  end

  defmodule V7SqliteDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("pk_accept_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule WritableIdSqliteDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("pk_accept_test_writable_id_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      attribute(:id, :uuid,
        primary_key?: true,
        writable?: true,
        allow_nil?: false
      )
    end

    actions do
      defaults([:read])
    end
  end

  defmodule V7SqliteLedger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.InboundDelivery]

    sqlite do
      table("pk_accept_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
      # the scope family: the SAME external event id legitimately recurs
      # across accounts — the pre-read must match the scope EXACTLY, not
      # over-select sibling scopes (review finding on the H2 fallback)
      attribute(:account_id, :string, allow_nil?: false)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("pk_accept_test_emitters")
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
        subscriptions(AshHooks.PkAcceptTest.Subscription)
        deliveries(AshHooks.PkAcceptTest.V7SqliteDelivery)
      end
    end
  end

  defmodule WritableIdEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("pk_accept_test_emitters")
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
        subscriptions(AshHooks.PkAcceptTest.Subscription)
        deliveries(AshHooks.PkAcceptTest.WritableIdSqliteDelivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.PkAcceptTest.Endpoint)
      resource(AshHooks.PkAcceptTest.Subscription)
      resource(AshHooks.PkAcceptTest.V7SqliteDelivery)
      resource(AshHooks.PkAcceptTest.WritableIdSqliteDelivery)
      resource(AshHooks.PkAcceptTest.V7SqliteLedger)
      resource(AshHooks.PkAcceptTest.Emitter)
      resource(AshHooks.PkAcceptTest.WritableIdEmitter)
    end
  end

  use ExUnit.Case, async: false

  alias Ash.Resource.Info, as: ResourceInfo
  alias Ash.Type.UUID, as: UUIDType
  alias AshHooks.{Dispatcher, Event, Ingress}
  alias AshHooks.Test.Repo

  @deliveries "pk_accept_test_deliveries"
  @writable_id_deliveries "pk_accept_test_writable_id_deliveries"
  @endpoints "pk_accept_test_endpoints"
  @subscriptions "pk_accept_test_subscriptions"
  @ledgers "pk_accept_test_ledgers"
  @payload Jason.encode!(%{"order" => 1})

  # ── runtime-compiled shapes (the transformer arms light up under cover) ──

  @compile_domain """
  defmodule AshHooks.PkAcceptTest.CompileDomain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.PkAcceptTest.V7Delivery)
      resource(AshHooks.PkAcceptTest.V7Ledger)
      resource(AshHooks.PkAcceptTest.DefaultDelivery)
      resource(AshHooks.PkAcceptTest.CustomPk)
    end
  end
  """

  @v7_delivery_resource """
  defmodule AshHooks.PkAcceptTest.V7Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.CompileDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.OutboundDelivery]

    attributes do
      uuid_v7_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end
  """

  @v7_ledger_resource """
  defmodule AshHooks.PkAcceptTest.V7Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.CompileDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.InboundDelivery]

    attributes do
      uuid_v7_primary_key(:id)
    end

    actions do
      defaults([:read])
    end
  end
  """

  @custom_pk_resource """
  defmodule AshHooks.PkAcceptTest.CustomPk do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.CompileDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.OutboundDelivery]

    attributes do
      uuid_primary_key(:custom_id)
      attribute(:id, :uuid, allow_nil?: false, default: &Ash.UUID.generate/0)
    end

    actions do
      defaults([:read])
    end
  end
  """

  @default_delivery_resource """
  defmodule AshHooks.PkAcceptTest.DefaultDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PkAcceptTest.CompileDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.OutboundDelivery]

    actions do
      defaults([:read])
    end
  end
  """

  setup_all do
    Code.compile_string(@compile_domain)
    create_tables!()

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@writable_id_deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@ledgers}")

      for mod <- [
            AshHooks.PkAcceptTest.V7Delivery,
            AshHooks.PkAcceptTest.V7Ledger,
            AshHooks.PkAcceptTest.DefaultDelivery,
            AshHooks.PkAcceptTest.CompileDomain
          ] do
        :code.purge(mod)
        :code.delete(mod)
      end
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@writable_id_deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@ledgers}")
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
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY,
      event_types TEXT NOT NULL,
      endpoint_id TEXT NOT NULL,
      signing_mode TEXT
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
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@writable_id_deliveries} (
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
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      attempt_token TEXT, send_lease_expires_at TEXT,
      enqueue_token TEXT, enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@writable_id_deliveries}_unique_delivery_index ON #{@writable_id_deliveries} (endpoint_id, event_uuid)"
    )

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@ledgers} (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
      account_id TEXT NOT NULL,
      external_event_id TEXT NOT NULL,
      external_event_type TEXT,
      payload TEXT NOT NULL,
      payload_digest TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'received',
      fencing_token INTEGER NOT NULL DEFAULT 0,
      lease_expires_at TEXT,
      error_class TEXT,
      attempts INTEGER NOT NULL DEFAULT 0
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@ledgers}_unique_ingest_index ON #{@ledgers} (provider, external_event_id, account_id)"
    )
  end

  describe "compile shape (H2): a non-writable uuid_v7 PK" do
    test "an OutboundDelivery resource with uuid_v7_primary_key compiles" do
      assert Enum.any?(Code.compile_string(@v7_delivery_resource), fn {m, _} ->
               m == AshHooks.PkAcceptTest.V7Delivery
             end)

      action = ResourceInfo.action(AshHooks.PkAcceptTest.V7Delivery, :dispatch)
      refute :id in action.accept, ":dispatch must not accept a non-writable PK (H2)"
      assert :event_uuid in action.accept
    after
      :code.purge(AshHooks.PkAcceptTest.V7Delivery)
      :code.delete(AshHooks.PkAcceptTest.V7Delivery)
    end

    test "an InboundDelivery ledger with uuid_v7_primary_key compiles" do
      assert Enum.any?(Code.compile_string(@v7_ledger_resource), fn {m, _} ->
               m == AshHooks.PkAcceptTest.V7Ledger
             end)

      action = ResourceInfo.action(AshHooks.PkAcceptTest.V7Ledger, :ingest)
      refute :id in action.accept, ":ingest must not accept a non-writable PK (H2)"
      assert :external_event_id in action.accept
    after
      :code.purge(AshHooks.PkAcceptTest.V7Ledger)
      :code.delete(AshHooks.PkAcceptTest.V7Ledger)
    end

    test "the package-injected writable PK keeps :id in accept (byte-identical default)" do
      assert Enum.any?(Code.compile_string(@default_delivery_resource), fn {m, _} ->
               m == AshHooks.PkAcceptTest.DefaultDelivery
             end)

      assert :id in ResourceInfo.action(AshHooks.PkAcceptTest.DefaultDelivery, :dispatch).accept
    after
      :code.purge(AshHooks.PkAcceptTest.DefaultDelivery)
      :code.delete(AshHooks.PkAcceptTest.DefaultDelivery)
    end

    test "a writable :id beside a differently named PK keeps :id in accept (cross-vendor P2)" do
      # this shape COMPILED and dispatched at HEAD (uuid_v7 was never its
      # problem) — narrowing its accept list would be a semver break, not
      # a correction
      assert Enum.any?(Code.compile_string(@custom_pk_resource), fn {m, _} ->
               m == AshHooks.PkAcceptTest.CustomPk
             end)

      assert :id in ResourceInfo.action(AshHooks.PkAcceptTest.CustomPk, :dispatch).accept
    after
      :code.purge(AshHooks.PkAcceptTest.CustomPk)
      :code.delete(AshHooks.PkAcceptTest.CustomPk)
    end
  end

  describe "classification on a non-writable PK (H2)" do
    test "dispatch classifies created then duplicate, one row, one enqueue, uuid_v7 ids" do
      ep =
        Ash.create!(Endpoint, %{url: "https://example.test/hook", secret_ref: "ref-1"},
          authorize?: false
        )

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      {:ok, event} = Event.new(type: :order_paid, payload: @payload)
      enqueue_calls = :counters.new(1, [])

      enqueue = fn _delivery, _event ->
        :counters.add(enqueue_calls, 1, 1)
        :ok
      end

      {:ok, first} = Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: enqueue)
      {:ok, second} = Dispatcher.dispatch(Emitter, :order_paid, event, enqueue: enqueue)

      assert [%{status: :created}] = first
      assert [%{status: :duplicate}] = second

      rows = Ash.read!(V7SqliteDelivery, authorize?: false)
      assert length(rows) == 1
      # the PK keeps the consumer's uuid_v7 shape (version nibble is 7),
      # not the package's uuid v4
      assert binary_part(hd(rows).id, 14, 1) == "7"
      assert :counters.get(enqueue_calls, 1) == 1
    end

    test "ingest classifies created then duplicate on re-delivery (claim fence holds)" do
      env = %{
        name: :counter,
        external_event_id: "evt-1",
        type_string: "counter.tick",
        payload: @payload,
        digest: "digest-1",
        scope: %{account_id: "acct-a"},
        tenant: nil
      }

      {:ok, created?, first_row} = Ingress.ingest_delivery(V7SqliteLedger, env)
      assert created? == true

      {:ok, dup?, second_row} = Ingress.ingest_delivery(V7SqliteLedger, env)
      assert dup? == false
      assert second_row.id == first_row.id

      assert [%{status: :received}] = Ash.read!(V7SqliteLedger, authorize?: false)
      assert binary_part(first_row.id, 14, 1) == "7"
    end

    test "a scoped pre-read classifies per scope, not per external id" do
      # the SAME (provider, external_event_id) exists for acct-a; acct-b
      # has never seen it — b's ingest is :created, a's re-delivery is
      # :duplicate, and the two rows coexist (scope_identity's premise)
      base = %{
        name: :counter,
        external_event_id: "evt-scope",
        type_string: "counter.tick",
        payload: @payload,
        digest: "digest-scope",
        tenant: nil
      }

      {:ok, true, _} =
        Ingress.ingest_delivery(V7SqliteLedger, Map.put(base, :scope, %{account_id: "acct-a"}))

      {:ok, true, _} =
        Ingress.ingest_delivery(V7SqliteLedger, Map.put(base, :scope, %{account_id: "acct-b"}))

      {:ok, false, _} =
        Ingress.ingest_delivery(V7SqliteLedger, Map.put(base, :scope, %{account_id: "acct-a"}))

      assert length(Ash.read!(V7SqliteLedger, authorize?: false)) == 2
    end
  end

  describe "legacy sole writable :id without a default" do
    test "dispatch supplies the UUID required by the consumer resource" do
      ep =
        Ash.create!(Endpoint, %{url: "https://example.test/hook", secret_ref: "ref-1"},
          authorize?: false
        )

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
        authorize?: false
      )

      {:ok, event} = Event.new(type: :order_paid, payload: @payload)

      assert {:ok, [%{status: :deferred}]} =
               Dispatcher.dispatch(WritableIdEmitter, :order_paid, event)

      assert [%{id: id}] = Ash.read!(WritableIdSqliteDelivery, authorize?: false)
      assert {:ok, _uuid} = UUIDType.cast_input(id, [])
    end
  end
end
