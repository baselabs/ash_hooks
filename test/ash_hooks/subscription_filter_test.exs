defmodule AshHooks.SubscriptionFilterTest do
  @moduledoc """
  Subscription filters: a subscription matches on DECLARED event attributes
  (a resource id, a region) — not just event type — evaluated in the
  dispatcher BEFORE any delivery row is created. Attribute values ride the
  event's metadata; the subscription resource declares the closed set of
  filterable attribute names, and a filter key outside that set never
  matches (fail closed).
  """

  defmodule ForceFilters do
    @moduledoc false
    use Ash.Resource.Change

    @impl true
    def change(changeset, _opts, _context) do
      Ash.Changeset.before_action(changeset, fn changeset ->
        Ash.Changeset.force_change_attribute(
          changeset,
          :event_filters,
          Ash.Changeset.get_argument(changeset, :filters)
        )
      end)
    end
  end

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
      defaults([:read, :create, :update])
      default_accept(:*)

      create :import_filters do
        accept [:endpoint_id]
        argument :filters, :map, allow_nil?: false
        skip_global_validations? true
        change AshHooks.SubscriptionFilterTest.ForceFilters
      end

      update :replace_filters do
        accept []
        argument :filters, :map, allow_nil?: false
        require_atomic? false
        skip_global_validations? true
        change AshHooks.SubscriptionFilterTest.ForceFilters
      end
    end

    subscription do
      endpoint_resource(AshHooks.SubscriptionFilterTest.Endpoint)
      # the closed set of attribute names subscriptions may filter on
      filter_attributes([:order_id, :region])
    end
  end

  for {name, layer} <- [
        {:PostgresSubscription, AshPostgres.DataLayer},
        {:EtsSubscription, Ash.DataLayer.Ets},
        {:SimpleSubscription, Ash.DataLayer.Simple}
      ] do
    resource = Module.concat(__MODULE__, name)

    configuration =
      case layer do
        AshPostgres.DataLayer ->
          quote do
            postgres do
              table "subfilter_postgres_subscriptions"
              repo(AshHooks.TestPostgres.Repo)
            end
          end

        Ash.DataLayer.Ets ->
          quote do
            ets do
              private? false
            end

            attributes do
              attribute :event_filters, :map, public?: true, default: %{}
            end
          end

        Ash.DataLayer.Simple ->
          quote do
          end
      end

    Code.eval_quoted(
      quote do
        defmodule unquote(resource) do
          @moduledoc false
          use Ash.Resource,
            domain: AshHooks.SubscriptionFilterTest.Domain,
            data_layer: unquote(layer),
            extensions: [AshHooks.Subscription]

          unquote(configuration)

          actions do
            defaults [:read, :create, :update]
            default_accept :*

            create :import_filters do
              accept [:endpoint_id]
              argument :filters, :map, allow_nil?: false
              skip_global_validations? true
              change AshHooks.SubscriptionFilterTest.ForceFilters
            end

            update :replace_filters do
              accept []
              argument :filters, :map, allow_nil?: false
              require_atomic? false
              skip_global_validations? true
              change AshHooks.SubscriptionFilterTest.ForceFilters
            end
          end

          subscription do
            endpoint_resource AshHooks.SubscriptionFilterTest.Endpoint
            filter_attributes [:order_id, :region, :day, :"1"]
          end
        end
      end
    )
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
      resource(AshHooks.SubscriptionFilterTest.PostgresSubscription)
      resource(AshHooks.SubscriptionFilterTest.EtsSubscription)
      resource(AshHooks.SubscriptionFilterTest.SimpleSubscription)
      resource(AshHooks.SubscriptionFilterTest.Delivery)
      resource(AshHooks.SubscriptionFilterTest.Emitter)
    end
  end

  use ExUnit.Case, async: false

  import Ash.Expr, only: [expr: 1]

  alias __MODULE__.{EtsSubscription, PostgresSubscription, SimpleSubscription}
  alias Ash.Error.Changes.InvalidAttribute
  alias AshHooks.Subscription, as: Filters
  alias AshHooks.Subscription.Changes.CheckHostFilters
  alias AshHooks.Test.Repo
  alias AshHooks.TestPostgres.Repo, as: PostgresRepo

  @endpoints "subfilter_endpoints"
  @subscriptions "subfilter_subscriptions"
  @deliveries "subfilter_deliveries"
  @emitters "subfilter_emitters"
  @postgres_subscriptions "subfilter_postgres_subscriptions"

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

    postgres? = System.get_env("ASH_HOOKS_POSTGRES") == "1"

    if postgres? do
      PostgresRepo.query!("""
      CREATE TABLE IF NOT EXISTS #{@postgres_subscriptions} (
        id UUID PRIMARY KEY, event_types TEXT[] NOT NULL, endpoint_id UUID NOT NULL,
        signing_mode TEXT, event_filters JSONB
      )
      """)
    end

    on_exit(fn ->
      Repo.query!("DROP TABLE IF EXISTS #{@deliveries}")
      Repo.query!("DROP TABLE IF EXISTS #{@subscriptions}")
      Repo.query!("DROP TABLE IF EXISTS #{@endpoints}")
      Repo.query!("DROP TABLE IF EXISTS #{@emitters}")
      if postgres?, do: PostgresRepo.query!("DROP TABLE IF EXISTS #{@postgres_subscriptions}")
    end)

    :ok
  end

  setup do
    Repo.query!("DELETE FROM #{@deliveries}")
    Repo.query!("DELETE FROM #{@subscriptions}")
    Repo.query!("DELETE FROM #{@endpoints}")
    Repo.query!("DELETE FROM #{@emitters}")

    if System.get_env("ASH_HOOKS_POSTGRES") == "1",
      do: PostgresRepo.query!("DELETE FROM #{@postgres_subscriptions}")

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

  for {resource, tags} <- [
        {Subscription, []},
        {PostgresSubscription, [postgres: true]},
        {EtsSubscription, []},
        {SimpleSubscription, []}
      ] do
    @tag tags
    @tag subscription_resource: resource
    test "filter validation on create and update for #{inspect(resource)}", %{
      subscription_resource: resource
    } do
      if resource == EtsSubscription, do: on_exit(fn -> Ash.DataLayer.Ets.stop(resource) end)

      endpoint_id = endpoint!().id
      attrs = %{endpoint_id: endpoint_id}

      subscription =
        Ash.create!(resource, Map.put(attrs, :event_filters, %{"region" => "initial"}),
          authorize?: false
        )

      for {filters, key, reason} <- [
            {%URI{}, "event_filters", "plain map"},
            {%{"unknown" => "west"}, ~s("unknown"), "not declared"},
            {%{unknown: "west"}, ":unknown", "not declared"},
            {%{{:unknown} => "west"}, "{:unknown}", "not declared"},
            {%{"region" => []}, ~s("region"), "nonempty list"}
          ] do
        assert {:error, %InvalidAttribute{field: :event_filters, message: message}} =
                 Filters.validate_filters(resource, filters)

        assert message =~ key
        assert message =~ reason

        attrs = Map.put(attrs, :event_filters, filters)

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 Ash.create(resource, attrs, authorize?: false)

        assert_filter_error(errors, key, reason)

        assert {:error, %Ash.Error.Invalid{errors: errors}} =
                 Ash.update(subscription, %{event_filters: filters}, authorize?: false)

        assert_filter_error(errors, key, reason)
      end

      for {filters, metadata} <- [
            {nil, %{}},
            {%{}, %{}},
            {%{region: "west"}, %{"region" => "west"}},
            {%{"region" => ["west", nil, true, 2, 1.5]}, %{"region" => 1.5}},
            {%{region: %{"names" => ["west"], "other" => []}},
             %{"region" => %{"names" => ["west"], "other" => []}}},
            {%{region: [%{"name" => "west"}, ["east"]]}, %{"region" => ["east"]}},
            {%{region: false}, %{"region" => false}},
            {%{region: nil}, %{"region" => nil}},
            {%{region: 1}, %{"region" => 1.0}}
          ] do
        assert_filter_round_trip(resource, subscription, filters, metadata)
      end
    end
  end

  defp assert_filter_round_trip(resource, subscription, filters, metadata) do
    assert :ok = Filters.validate_filters(resource, filters)

    created =
      Ash.create!(resource, %{endpoint_id: subscription.endpoint_id, event_filters: filters},
        authorize?: false
      )

    updated = Ash.update!(subscription, %{event_filters: filters}, authorize?: false)

    for row <- [created, updated] do
      row =
        if resource == SimpleSubscription,
          do: row,
          else: Ash.get!(resource, row.id, authorize?: false)

      assert string_keys(row.event_filters) === string_keys(filters)
      assert Filters.matches_filters?(row, metadata)
    end
  end

  test "an improper any-of list is refused by the import check and injected type" do
    attrs = %{endpoint_id: endpoint!().id, event_filters: %{region: [1 | 2]}}
    sub = Ash.create!(Subscription, %{endpoint_id: attrs.endpoint_id}, authorize?: false)

    assert {:error, error} = Filters.validate_filters(Subscription, attrs.event_filters)
    assert_filter_error([error], ":region", "proper list")

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(Subscription, attrs, authorize?: false)

    assert_filter_error(errors, ":region", "proper list")

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.update(sub, %{event_filters: attrs.event_filters}, authorize?: false)

    assert_filter_error(errors, ":region", "proper list")
  end

  @tag :postgres
  test "PostgreSQL accepts filter values supported by its map codec" do
    endpoint_id = endpoint!().id

    for {filters, stored} <- [
          {%{region: :west}, %{"region" => "west"}},
          {%{region: %{name: "west"}}, %{"region" => %{"name" => "west"}}},
          {%{day: ~D[2026-11-27]}, %{"day" => "2026-11-27"}},
          {%{region: Decimal.new("1.25")}, %{"region" => "1.25"}},
          {%{1 => "west"}, %{"1" => "west"}}
        ] do
      assert :ok = Filters.validate_filters(PostgresSubscription, filters)

      sub =
        Ash.create!(PostgresSubscription, %{endpoint_id: endpoint_id, event_filters: filters},
          authorize?: false
        )

      persisted = Ash.get!(PostgresSubscription, sub.id, authorize?: false)
      assert persisted.event_filters == stored
      assert Filters.matches_filters?(persisted, stored)
    end
  end

  test "ETS accepts atom and tuple filter values" do
    on_exit(fn -> Ash.DataLayer.Ets.stop(EtsSubscription) end)
    endpoint_id = endpoint!().id

    for value <- [:west, {:west, 1}, <<0, 255>>] do
      filters = %{"region" => value}
      assert :ok = Filters.validate_filters(EtsSubscription, filters)

      sub =
        Ash.create!(EtsSubscription, %{endpoint_id: endpoint_id, event_filters: filters},
          authorize?: false
        )

      persisted = Ash.get!(EtsSubscription, sub.id, authorize?: false)
      assert persisted.event_filters === filters
      assert Filters.matches_filters?(persisted, filters)
    end
  end

  test "JSON text is cast before checking filters" do
    attrs = %{endpoint_id: endpoint!().id, event_filters: ~s({"region":{"name":"west"}})}

    assert :ok = Filters.validate_filters(Subscription, attrs.event_filters)
    assert :ok = Filters.validate_filters(Subscription, "")

    assert %{event_filters: %{"region" => %{"name" => "west"}}} =
             sub = Ash.create!(Subscription, attrs, authorize?: false)

    assert %{event_filters: nil} =
             Ash.update!(sub, %{event_filters: ""}, authorize?: false)

    assert {:error, %InvalidAttribute{message: message}} =
             Filters.validate_filters(Subscription, "not a map")

    assert message =~ "plain map"

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(Subscription, %{attrs | event_filters: "not a map"}, authorize?: false)

    assert_filter_error(errors, "event_filters", "plain map")
  end

  test "bulk create rejects the invalid row and stores the valid row" do
    endpoint_id = endpoint!().id

    assert %Ash.BulkResult{status: :partial_success, records: [valid], errors: [error]} =
             Ash.bulk_create(
               [
                 %{endpoint_id: endpoint_id, event_filters: %{"region" => "west"}},
                 %{endpoint_id: endpoint_id, event_filters: %{"region" => []}}
               ],
               Subscription,
               :create,
               authorize?: false,
               return_errors?: true,
               return_records?: true,
               stop_on_error?: false,
               transaction: false
             )

    assert_filter_error([error], ~s("region"), "nonempty list")
    assert [%{event_filters: %{"region" => "west"}}] = Ash.read!(Subscription, authorize?: false)
    assert valid.event_filters == %{"region" => "west"}
  end

  test "create validates upsert filters before overwriting an existing row" do
    endpoint = endpoint!()
    stored = subscribe!(endpoint, ["order_paid"], %{"region" => "west"})

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.create(
               Subscription,
               %{id: stored.id, endpoint_id: endpoint.id, event_filters: %{"region" => []}},
               authorize?: false,
               upsert?: true,
               upsert_fields: [:event_filters]
             )

    assert_filter_error(errors, ~s("region"), "nonempty list")

    assert Ash.get!(Subscription, stored.id, authorize?: false).event_filters ==
             %{"region" => "west"}
  end

  test "before-action writes are checked on create and update even when globals are skipped" do
    on_exit(fn -> Ash.DataLayer.Ets.stop(EtsSubscription) end)
    endpoint_id = endpoint!().id

    for resource <- [Subscription, EtsSubscription] do
      attrs = %{endpoint_id: endpoint_id, filters: %{"region" => "west"}}

      sub = Ash.create!(resource, attrs, action: :import_filters, authorize?: false)
      assert sub.event_filters == %{"region" => "west"}

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.create(resource, %{attrs | filters: %{region: []}},
                 action: :import_filters,
                 authorize?: false
               )

      assert_filter_error(errors, ":region", "nonempty list")

      assert %{event_filters: %{"region" => "east"}} =
               Ash.update!(sub, %{filters: %{"region" => "east"}},
                 action: :replace_filters,
                 authorize?: false
               )

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               Ash.update(sub, %{filters: %{region: []}},
                 action: :replace_filters,
                 authorize?: false
               )

      assert_filter_error(errors, ":region", "nonempty list")
    end
  end

  test "host maps refuse invalid filters during automatic and explicit atomic updates" do
    on_exit(fn -> Ash.DataLayer.Ets.stop(EtsSubscription) end)

    sub =
      Ash.create!(
        EtsSubscription,
        %{endpoint_id: endpoint!().id, event_filters: %{"region" => "west"}},
        authorize?: false
      )

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.update(sub, %{event_filters: %{"unknown" => "west"}}, authorize?: false)

    assert_filter_error(errors, ~s("unknown"), "not declared")

    query = Ash.Query.for_read(EtsSubscription, :read)

    assert %Ash.BulkResult{status: :error, errors: [error]} =
             Ash.bulk_update(query, :update, %{event_filters: %{"region" => []}},
               strategy: [:atomic],
               authorize?: false,
               return_errors?: true
             )

    assert_filter_error([error], ~s("region"), "nonempty list")

    assert Ash.get!(EtsSubscription, sub.id, authorize?: false).event_filters ==
             %{"region" => "west"}
  end

  test "the host atomic change checks literal atomics and leaves expressions alone" do
    base = Ash.Changeset.new(EtsSubscription)
    context = %Ash.Resource.Change.Context{}

    invalid = Ash.Changeset.atomic_update(base, :event_filters, {:atomic, %{"region" => []}})

    assert {:error, error} = CheckHostFilters.atomic(invalid, [], context)
    assert_filter_error([error], ~s("region"), "nonempty list")

    expression = Ash.Changeset.atomic_update(base, :event_filters, {:atomic, expr(event_filters)})
    assert {:ok, ^expression} = CheckHostFilters.atomic(expression, [], context)
  end

  @tag :postgres
  test "an atomic query update checks filter literals before writing" do
    sub = Ash.create!(PostgresSubscription, %{endpoint_id: endpoint!().id}, authorize?: false)

    opts = [authorize?: false, strategy: [:atomic], return_errors?: true, return_records?: true]
    query = Ash.Query.for_read(PostgresSubscription, :read)

    assert %Ash.BulkResult{status: :success, records: [%{event_filters: %{"region" => "west"}}]} =
             Ash.bulk_update(query, :update, %{event_filters: %{region: "west"}}, opts)

    assert %Ash.BulkResult{status: :error, errors: [error]} =
             Ash.bulk_update(query, :update, %{event_filters: %{region: []}}, opts)

    assert_filter_error([error], ":region", "nonempty list")

    assert %Ash.BulkResult{status: :error, errors: [error]} =
             Ash.bulk_update(
               query,
               :update,
               %{},
               Keyword.put(opts, :atomic_update, %{event_filters: %{region: []}})
             )

    assert_filter_error([error], ":region", "nonempty list")

    assert Ash.get!(PostgresSubscription, sub.id, authorize?: false).event_filters ==
             %{"region" => "west"}
  end

  @tag :postgres
  test "atomic filter expressions retain Ash's unchecked write path" do
    sub = Ash.create!(PostgresSubscription, %{endpoint_id: endpoint!().id}, authorize?: false)
    query = Ash.Query.for_read(PostgresSubscription, :read)
    filter_expression = expr(fragment("jsonb_build_object('unknown', 'west')"))

    for value <- [filter_expression, {:atomic, filter_expression}] do
      assert %Ash.BulkResult{
               status: :success,
               records: [%{event_filters: %{"unknown" => "west"}}]
             } =
               Ash.bulk_update(query, :update, %{},
                 atomic_update: %{event_filters: value},
                 authorize?: false,
                 strategy: [:atomic],
                 return_errors?: true,
                 return_records?: true
               )

      assert Ash.get!(PostgresSubscription, sub.id, authorize?: false).event_filters ==
               %{"unknown" => "west"}
    end
  end

  defp string_keys(nil), do: nil
  defp string_keys(filters), do: Map.new(filters, fn {key, value} -> {to_string(key), value} end)

  defp assert_filter_error(errors, key, reason) do
    assert Enum.any?(errors, &filter_error?(&1, key, reason))
  end

  defp filter_error?(%InvalidAttribute{field: :event_filters, message: message}, key, reason),
    do: message =~ key and message =~ reason

  defp filter_error?(%Ash.Error.Invalid{errors: errors}, key, reason),
    do: Enum.any?(errors, &filter_error?(&1, key, reason))

  defp filter_error?(_error, _key, _reason), do: false

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
