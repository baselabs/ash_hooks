defmodule AshHooks.SubscriptionTypingTest do
  @moduledoc """
  Consumer scenario (H8, the first-serious-consumer integration): a
  consumer redeclares `event_types` as a CLOSED ATOM enum (`{:array,
  :atom}`, `one_of:` + `min_length: 1` — sirtify's register shape,
  webhook_endpoint.ex:118-125). The package's binary matching
  (`"*" in types or type in types`) silently delivered NOTHING for such
  rows — zero deliveries, no error. Matching normalizes entries to the
  event's canonical string, so atom-typed registers match exactly like
  string-typed ones; the consumer's own attribute declaration replaces
  the injected one, so the closed enum and its constraints still govern
  the write path (no wildcard default is forced on them).
  """

  defmodule Endpoint do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionTypingTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Endpoint]

    sqlite do
      table("subscription_typing_test_endpoints")
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
      domain: AshHooks.SubscriptionTypingTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.Subscription]

    sqlite do
      table("subscription_typing_test_subscriptions")
      repo(AshHooks.Test.Repo)
    end

    attributes do
      # the consumer's closed atom register replaces the injected
      # {:array, :string} default ["*"] (add_new_attribute stands down)
      attribute(:event_types, {:array, :atom},
        allow_nil?: false,
        public?: true,
        constraints: [min_length: 1, items: [one_of: [:order_paid, :order_shipped]]]
      )
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end

    subscription do
      endpoint_resource(AshHooks.SubscriptionTypingTest.Endpoint)
    end
  end

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionTypingTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("subscription_typing_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Emitter do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.SubscriptionTypingTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks]

    sqlite do
      table("subscription_typing_test_emitters")
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
        subscriptions(AshHooks.SubscriptionTypingTest.Subscription)
        deliveries(AshHooks.SubscriptionTypingTest.Delivery)
      end
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.SubscriptionTypingTest.Endpoint)
      resource(AshHooks.SubscriptionTypingTest.Subscription)
      resource(AshHooks.SubscriptionTypingTest.Delivery)
      resource(AshHooks.SubscriptionTypingTest.Emitter)
    end
  end

  use ExUnit.Case, async: false

  alias AshHooks.{Dispatcher, Event}
  alias AshHooks.Test.Repo

  @endpoints "subscription_typing_test_endpoints"
  @subscriptions "subscription_typing_test_subscriptions"
  @deliveries "subscription_typing_test_deliveries"
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

    # the atom enum round-trips sqlite as JSON — same TEXT column
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
      dispatch_source TEXT NOT NULL DEFAULT 'v1:direct:unbound',
      dispatch_route TEXT NOT NULL DEFAULT 'v1:route:unbound',
      status TEXT NOT NULL DEFAULT 'pending',
      attempts INTEGER NOT NULL DEFAULT 0,
      attempt_token TEXT,
      send_lease_expires_at TEXT,
      enqueue_token TEXT,
      enqueue_lease_expires_at TEXT,
      endpoint_snapshot TEXT,
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
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    :ok
  end

  defp endpoint! do
    Ash.create!(Endpoint, %{url: "https://example.test/hook", secret_ref: "ref-1"},
      authorize?: false
    )
  end

  defp event! do
    Event.new(type: :order_paid, payload: @payload) |> elem(1)
  end

  describe "atom-typed registers (H8a)" do
    test "an atom entry matches its canonical string event type" do
      assert AshHooks.Subscription.matches?(%{event_types: [:order_paid]}, "order_paid") ==
               true
    end

    test "an atom wildcard matches everything" do
      assert AshHooks.Subscription.matches?(%{event_types: [:*]}, "anything_at_all") == true
    end

    test "a mixed list matches on either representation" do
      assert AshHooks.Subscription.matches?(
               %{event_types: [:order_paid, "order_shipped"]},
               "order_paid"
             )

      assert AshHooks.Subscription.matches?(
               %{event_types: [:order_paid, "order_shipped"]},
               "order_shipped"
             )

      refute AshHooks.Subscription.matches?(
               %{event_types: [:order_paid, "order_shipped"]},
               "other"
             )
    end

    test "string-typed rows keep the exact-match semantics (the default posture)" do
      assert AshHooks.Subscription.matches?(%{event_types: ["*"]}, "order_paid")
      assert AshHooks.Subscription.matches?(%{event_types: ["order_paid"]}, "order_paid")
      refute AshHooks.Subscription.matches?(%{event_types: ["order_paid"]}, "order_shipped")
      refute AshHooks.Subscription.matches?(%{}, "order_paid")
    end

    test "an exotic entry is unmatchable, never a fanout-aborting raise (totality)" do
      # one map/tuple-typed entry must not abort the whole dispatch (the
      # match runs outside the per-endpoint rescue) — it simply does not
      # match, the pre-normalization behavior for such rows
      assert AshHooks.Subscription.matches?(
               %{event_types: [%{"weird" => 1}, :order_paid]},
               "order_paid"
             )

      refute AshHooks.Subscription.matches?(%{event_types: [%{"weird" => 1}]}, "order_paid")
    end

    test "dispatch delivers through an atom-typed subscription — no silent zero-fanout" do
      ep = endpoint!()

      Ash.create!(Subscription, %{endpoint_id: ep.id, event_types: [:order_paid]},
        authorize?: false
      )

      {:ok, results} =
        Dispatcher.dispatch(Emitter, :order_paid, event!(), enqueue: fn _d, _e -> :ok end)

      ep_id = ep.id
      assert [%{status: :created, endpoint_id: ^ep_id}] = results
      assert [%{event_type: "order_paid"}] = Ash.read!(Delivery, authorize?: false)
    end
  end

  describe "the closed-enum register contract (H8b)" do
    test "the consumer's one_of constraints still govern the write path" do
      ep = endpoint!()

      assert {:error, _} =
               Ash.create(Subscription, %{endpoint_id: ep.id, event_types: [:not_in_register]},
                 authorize?: false
               )
    end

    test "the empty list is refused by the consumer's min_length" do
      ep = endpoint!()

      assert {:error, _} =
               Ash.create(Subscription, %{endpoint_id: ep.id, event_types: []}, authorize?: false)
    end
  end
end
