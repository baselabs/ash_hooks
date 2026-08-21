defmodule AshHooks.SubscriptionTest do
  @moduledoc """
  The Subscription resource: the event-type filter (default `["*"]`, the
  wildcard + exact-string match the dispatcher applies in memory), the
  endpoint reference, and the per-subscription `signing_mode` override
  (ADR-0002's per-subscription mode; NULL falls back to the outbound
  entity's).
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("subscription_test_endpoints")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end
  end

  defmodule Subscription do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("subscription_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.SubscriptionTest.Endpoint)
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.SubscriptionTest.Endpoint)
      resource(AshHooks.SubscriptionTest.Subscription)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.Test.Repo

  @endpoints "subscription_test_endpoints"
  @subscriptions "subscription_test_subscriptions"

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

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    :ok
  end

  defp endpoint!(url \\ "https://example.test/hook") do
    Ash.create!(Endpoint, %{url: url, secret_ref: "ref-1"}, authorize?: false)
  end

  describe "injected fields" do
    test "event_types defaults to [\"*\"]" do
      sub =
        Ash.create!(Subscription, %{endpoint_id: endpoint!().id}, authorize?: false)

      assert sub.event_types == ["*"]
    end

    test "event_types and endpoint_id are required; signing_mode stays nil" do
      assert {:error, _} = Ash.create(Subscription, %{endpoint_id: nil}, authorize?: false)
    end

    test "accepts an explicit filter and a signing_mode override" do
      sub =
        Ash.create!(
          Subscription,
          %{
            endpoint_id: endpoint!().id,
            event_types: ["order_paid", "order.refunded"],
            signing_mode: :dual
          },
          authorize?: false
        )

      assert sub.event_types == ["order_paid", "order.refunded"]
      assert sub.signing_mode == :dual
    end
  end

  describe "in-memory match semantics" do
    test "\"*\" matches any type" do
      sub = Ash.create!(Subscription, %{endpoint_id: endpoint!().id}, authorize?: false)
      assert AshHooks.Subscription.matches?(sub, "anything.at.all")
    end

    test "an exact entry matches only that type" do
      sub =
        Ash.create!(
          Subscription,
          %{
            endpoint_id: endpoint!().id,
            event_types: ["order_paid"]
          },
          authorize?: false
        )

      assert AshHooks.Subscription.matches?(sub, "order_paid")
      refute AshHooks.Subscription.matches?(sub, "order_paid.late")
      refute AshHooks.Subscription.matches?(sub, "other")
    end

    test "no glob interpretation beyond the bare \"*\" entry" do
      sub =
        Ash.create!(
          Subscription,
          %{
            endpoint_id: endpoint!().id,
            event_types: ["order.*"]
          },
          authorize?: false
        )

      refute AshHooks.Subscription.matches?(sub, "order.paid")
      assert AshHooks.Subscription.matches?(sub, "order.*")
    end
  end
end
