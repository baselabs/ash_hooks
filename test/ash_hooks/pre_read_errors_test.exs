defmodule AshHooks.PreReadErrorsTest do
  @moduledoc """
  The error arms of the non-writable-PK classification paths (H2): a
  pre-read that fails, and an upsert that fails AFTER a clean pre-read,
  must surface as errors — never silently classified, never retried into
  a duplicate-claiming create.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Ash.Error.Query.InvalidQuery

  defmodule FailingReadPrep do
    @moduledoc false
    use Ash.Resource.Preparation

    @impl true
    def prepare(query, _ctx, _opts) do
      Ash.Query.add_error(query, InvalidQuery.exception(message: "forced"))
    end
  end

  defmodule FailingCreateChange do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _ctx, _opts) do
      Ash.Changeset.add_error(
        changeset,
        InvalidAttribute.exception(field: :event_uuid, message: "forced")
      )
    end
  end

  defmodule UnreadableDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("pre_read_errors_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
    end

    preparations do
      prepare({FailingReadPrep, []})
    end

    actions do
      defaults([:read])
    end
  end

  defmodule UnwritableDelivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("pre_read_errors_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
    end

    changes do
      change({FailingCreateChange, []})
    end

    actions do
      defaults([:read])
    end
  end

  defmodule UnreadableLedger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.InboundDelivery]

    sqlite do
      table("pre_read_errors_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
    end

    preparations do
      prepare({FailingReadPrep, []})
    end

    actions do
      defaults([:read])
    end
  end

  defmodule UnwritableLedger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.InboundDelivery]

    sqlite do
      table("pre_read_errors_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_v7_primary_key(:id)
    end

    changes do
      change({FailingCreateChange, []})
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("pre_read_errors_test_endpoints")
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
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("pre_read_errors_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.PreReadErrorsTest.Endpoint)
    end
  end

  defmodule UnreadableEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("pre_read_errors_test_emitters")
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
        subscriptions(AshHooks.PreReadErrorsTest.Subscription)
        deliveries(AshHooks.PreReadErrorsTest.UnreadableDelivery)
      end
    end
  end

  defmodule UnwritableEmitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.PreReadErrorsTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("pre_read_errors_test_emitters")
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
        subscriptions(AshHooks.PreReadErrorsTest.Subscription)
        deliveries(AshHooks.PreReadErrorsTest.UnwritableDelivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.PreReadErrorsTest.Endpoint)
      resource(AshHooks.PreReadErrorsTest.Subscription)
      resource(AshHooks.PreReadErrorsTest.UnreadableDelivery)
      resource(AshHooks.PreReadErrorsTest.UnwritableDelivery)
      resource(AshHooks.PreReadErrorsTest.UnreadableLedger)
      resource(AshHooks.PreReadErrorsTest.UnwritableLedger)
      resource(AshHooks.PreReadErrorsTest.UnreadableEmitter)
      resource(AshHooks.PreReadErrorsTest.UnwritableEmitter)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.{Dispatcher, Event, Ingress}
  alias AshHooks.Test.Repo

  @endpoints "pre_read_errors_test_endpoints"
  @subscriptions "pre_read_errors_test_subscriptions"
  @ledgers "pre_read_errors_test_ledgers"
  @deliveries "pre_read_errors_test_deliveries"
  @payload Jason.encode!(%{"order" => 1})

  setup_all do
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

    # the UnwritableLedger pre-read must succeed (its create fails) — a
    # missing table would fail the read first
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@ledgers} (
      id TEXT PRIMARY KEY,
      provider TEXT NOT NULL,
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
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@ledgers}_unique_ingest_index ON #{@ledgers} (provider, external_event_id)"
    )

    # the UnwritableDelivery pre-read must succeed (its create fails) —
    # a missing table would fail the read first
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
      next_attempt_at TEXT
    )
    """)

    Repo.query!(
      "CREATE UNIQUE INDEX IF NOT EXISTS #{@deliveries}_unique_delivery_index ON #{@deliveries} (endpoint_id, event_uuid)"
    )

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@ledgers}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@ledgers}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    :ok
  end

  setup do
    ep =
      Ash.create!(
        Endpoint,
        %{url: "https://example.test/hook", secret_ref: "ref-1"},
        authorize?: false
      )

    Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: ["order_paid"]},
      authorize?: false
    )

    {:ok, event: Event.new(type: :order_paid, payload: @payload) |> elem(1)}
  end

  describe "the outbound pre-read error arms (H2)" do
    test "a failing classification pre-read surfaces as :endpoint_error (the injected one)", %{
      event: event
    } do
      assert {:ok, [entry]} =
               Dispatcher.dispatch(UnreadableEmitter, :order_paid, event,
                 enqueue: fn _d, _e -> :ok end
               )

      assert entry.status == :endpoint_error
      # the message proves the PRE-READ branch fired — a wrong-path
      # NoSuchInput would also satisfy a bare status assertion
      assert inspect(entry.error) =~ "forced"
    end

    test "a failing upsert AFTER a clean pre-read surfaces as :endpoint_error (the injected one)",
         %{event: event} do
      assert {:ok, [entry]} =
               Dispatcher.dispatch(UnwritableEmitter, :order_paid, event,
                 enqueue: fn _d, _e -> :ok end
               )

      assert entry.status == :endpoint_error
      assert inspect(entry.error) =~ "forced"
    end
  end

  describe "the inbound pre-read error arms (H2)" do
    test "a failing classification pre-read returns the error (the injected one)" do
      env = %{
        name: :counter,
        external_event_id: "evt-1",
        type_string: "counter.tick",
        payload: @payload,
        digest: "digest-1",
        scope: %{},
        tenant: nil
      }

      # the message proves the PRE-READ branch fired — an accept-list
      # NoSuchInput from a wrong path would also match a bare class
      # assertion (cross-vendor review finding on test vacuity)
      assert {:error, error} = Ingress.ingest_delivery(UnreadableLedger, env)
      assert Exception.message(error) =~ "forced"
    end

    test "a failing ingest create AFTER a clean pre-read returns the error (the injected one)" do
      env = %{
        name: :counter,
        external_event_id: "evt-2",
        type_string: "counter.tick",
        payload: @payload,
        digest: "digest-2",
        scope: %{},
        tenant: nil
      }

      assert {:error, error} = Ingress.ingest_delivery(UnwritableLedger, env)
      assert Exception.message(error) =~ "forced"
    end
  end
end
