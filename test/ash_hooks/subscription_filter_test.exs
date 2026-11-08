defmodule AshHooks.SubscriptionFilterTest do
  @moduledoc """
  Subscription filters: a subscription matches on DECLARED event attributes
  (a resource id, a region) — not just event type — evaluated in the
  dispatcher BEFORE any delivery row is created. Attribute values ride the
  event's metadata; the subscription resource declares the closed set of
  filterable attribute names, and a filter key outside that set never
  matches (fail closed).
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionFilterTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("subfilter_endpoints")
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
      domain: AshHooks.SubscriptionFilterTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("subfilter_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.SubscriptionFilterTest.Endpoint)
      # the closed set of attribute names subscriptions may filter on
      filter_attributes([:order_id, :region])
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionFilterTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("subfilter_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionFilterTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("subfilter_emitters")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      uuid_primary_key(:id)
    end

    actions do
      defaults([:read, :create])
    end

    webhooks do
      outbound :order_paid do
        subscriptions(AshHooks.SubscriptionFilterTest.Subscription)
        deliveries(AshHooks.SubscriptionFilterTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.SubscriptionFilterTest.Endpoint)
      resource(AshHooks.SubscriptionFilterTest.Subscription)
      resource(AshHooks.SubscriptionFilterTest.Delivery)
      resource(AshHooks.SubscriptionFilterTest.Emitter)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo

  @endpoints "subfilter_endpoints"
  @subscriptions "subfilter_subscriptions"
  @deliveries "subfilter_deliveries"
  @emitters "subfilter_emitters"

  setup_all do
    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@endpoints} (
      id TEXT PRIMARY KEY, url TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'enabled',
      secret_ref TEXT NOT NULL, previous_secret_ref TEXT, legacy_secret_ref TEXT,
      legacy_previous_secret_ref TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@subscriptions} (
      id TEXT PRIMARY KEY, event_types TEXT NOT NULL, endpoint_id TEXT NOT NULL,
      signing_mode TEXT, event_filters TEXT
    )
    """)

    Repo.query!("""
    CREATE TABLE IF NOT EXISTS #{@deliveries} (
      id TEXT PRIMARY KEY, event_uuid TEXT NOT NULL, event_type TEXT NOT NULL,
      payload BLOB NOT NULL, endpoint_id TEXT NOT NULL, subscription_id TEXT,
      signing_mode TEXT, status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0, response_status INTEGER,
      response_snippet TEXT, last_error TEXT, next_attempt_at TEXT,
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

    Repo.query!("CREATE TABLE IF NOT EXISTS #{@emitters} (id TEXT PRIMARY KEY)")

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@emitters}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@emitters}")
    :ok
  end

  defp endpoint! do
    Ash.create!(Endpoint, %{url: "https://hooks.example.test/hook", secret_ref: "sf-main"},
      authorize?: false
    )
  end

  defp subscribe!(endpoint, event_types, filters) do
    Ash.create!(
      Subscription,
      %{endpoint_id: endpoint.id, event_types: event_types, event_filters: filters},
      authorize?: false
    )
  end

  defp dispatch!(metadata) do
    {:ok, event} =
      AshHooks.Event.new(
        type: "order_paid",
        payload: Jason.encode!(%{"order" => 1}),
        metadata: metadata
      )

    AshHooks.dispatch(Emitter, :order_paid, event)
  end

  test "a subscription with matching filters receives the delivery" do
    endpoint = endpoint!()
    subscribe!(endpoint, ["order_paid"], %{"order_id" => "o-1"})

    assert {:ok, [%{status: :deferred}]} = dispatch!(%{"order_id" => "o-1"})
    assert [%{endpoint_id: id}] = Ash.read!(Delivery, authorize?: false)
    assert id == endpoint.id
  end

  test "a subscription with non-matching filters receives NOTHING (no row)" do
    endpoint = endpoint!()
    subscribe!(endpoint, ["order_paid"], %{"order_id" => "o-1"})

    assert {:ok, []} = dispatch!(%{"order_id" => "o-2"})
    assert Ash.read!(Delivery, authorize?: false) == []
  end

  test "an event missing a filtered attribute does not match" do
    endpoint = endpoint!()
    subscribe!(endpoint, ["order_paid"], %{"order_id" => "o-1"})

    assert {:ok, []} = dispatch!(%{"region" => "eu"})
    assert Ash.read!(Delivery, authorize?: false) == []
  end

  test "a filterless subscription matches everything (type-gated as before)" do
    endpoint = endpoint!()
    subscribe!(endpoint, ["order_paid"], nil)

    assert {:ok, [%{status: :deferred}]} = dispatch!(%{"order_id" => "whatever"})
    assert length(Ash.read!(Delivery, authorize?: false)) == 1
  end

  test "multiple filters AND together; list values match any-of" do
    endpoint = endpoint!()
    other = endpoint!()

    subscribe!(endpoint, ["order_paid"], %{"order_id" => "o-1", "region" => "eu"})
    subscribe!(other, ["order_paid"], %{"region" => ["us", "apac"]})

    # eu + o-1 matches the AND; "eu" is not in [us, apac]
    assert {:ok, results} = dispatch!(%{"order_id" => "o-1", "region" => "eu"})
    assert [%{endpoint_id: id}] = results
    assert id == endpoint.id

    # apac matches the any-of; the AND subscription's order_id is missing
    assert {:ok, [any_of]} = dispatch!(%{"region" => "apac"})
    assert any_of.endpoint_id == other.id
  end

  test "a malformed event_filters value never matches" do
    endpoint = endpoint!()

    Repo.query!(
      """
      INSERT INTO #{@subscriptions} (id, event_types, endpoint_id, event_filters)
      VALUES (?, '["order_paid"]', ?, 'not-json-map')
      """,
      [Ash.UUID.generate(), endpoint.id]
    )

    # the :map cast fails on read... the row still must never deliver —
    # exercised through matches_filters? directly with a non-map shape
    sub =
      struct!(Subscription, %{
        id: Ash.UUID.generate(),
        event_types: ["order_paid"],
        event_filters: :not_a_map
      })

    refute AshHooks.Subscription.matches_filters?(sub, %{"order_id" => "o-1"})
  end

  test "a filter key outside the declared set never matches (fail closed)" do
    endpoint = endpoint!()

    Repo.query!(
      """
      INSERT INTO #{@subscriptions} (id, event_types, endpoint_id, event_filters)
      VALUES (?, '["order_paid"]', ?, ?)
      """,
      [Ash.UUID.generate(), endpoint.id, Jason.encode!(%{"not_declared" => "x"})]
    )

    assert {:ok, []} = dispatch!(%{"not_declared" => "x"})
    assert Ash.read!(Delivery, authorize?: false) == []
  end
end
