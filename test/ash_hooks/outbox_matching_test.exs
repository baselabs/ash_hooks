Code.require_file("outbox_process.exs", __DIR__)
Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.OutboxMatching.Preparation do
  use Ash.Resource.Preparation
  alias Ash.DataLayer.Simple

  def prepare(query, _opts, _context) do
    {owner, rows} = Application.fetch_env!(:ash_hooks, query.resource)

    query =
      if Ash.DataLayer.data_layer(query.resource) == Simple,
        do: Simple.set_data(query, rows),
        else: query

    Ash.Query.after_action(query, fn _query, records ->
      send(owner, {:selected, query.resource, Enum.map(records, & &1.id)})
      {:ok, records}
    end)
  end
end

defmodule AshHooks.OutboxMatching.CustomString do
  use Ash.Type.NewType, subtype_of: :string
end

defmodule AshHooks.OutboxMatching.CustomMap do
  use Ash.Type.NewType, subtype_of: :map
end

defmodule AshHooks.OutboxMatching.CustomBoolean do
  use Ash.Type.NewType, subtype_of: :boolean
end

for {name, layer, shape} <- [
      {:EtsStrings, Ash.DataLayer.Ets, :strings},
      {:EtsAtoms, Ash.DataLayer.Ets, :closed_atoms},
      {:SimpleStrings, Ash.DataLayer.Simple, :strings},
      {:SimpleAtoms, Ash.DataLayer.Simple, :closed_atoms},
      {:EtsOpenAtoms, Ash.DataLayer.Ets, :open_atoms},
      {:SimpleOpenAtoms, Ash.DataLayer.Simple, :open_atoms},
      {:EtsCustom, Ash.DataLayer.Ets, :custom},
      {:SimpleCustom, Ash.DataLayer.Simple, :custom},
      {:EtsEmptyAtoms, Ash.DataLayer.Ets, :empty_atoms},
      {:SimpleEmptyAtoms, Ash.DataLayer.Simple, :empty_atoms},
      {:EtsNullablePause, Ash.DataLayer.Ets, :nullable_pause},
      {:SimpleNullablePause, Ash.DataLayer.Simple, :nullable_pause}
    ] do
  subscription = Module.concat([AshHooks.OutboxMatching, name, Subscription])
  emitter = Module.concat([AshHooks.OutboxMatching, name, Emitter])

  ets_configuration =
    if layer == Ash.DataLayer.Ets do
      quote do
        ets do
          private? false
        end
      end
    end

  Code.eval_quoted(
    quote do
      defmodule unquote(subscription) do
        use Ash.Resource,
          domain: AshHooks.OutboxMatching.Domain,
          data_layer: unquote(layer),
          extensions: [AshHooks.Subscription]

        unquote(ets_configuration)

        attributes do
          attribute :org_id, :string, allow_nil?: false

          case unquote(shape) do
            :closed_atoms ->
              attribute :event_types, {:array, :atom},
                public?: true,
                constraints: [items: [one_of: [:changed, :other, :*]]]

            :empty_atoms ->
              attribute :event_types, {:array, :atom},
                public?: true,
                constraints: [items: [one_of: [:other]]]

            :open_atoms ->
              attribute :event_types, {:array, :atom}, public?: true

            :custom ->
              attribute :event_types, {:array, AshHooks.OutboxMatching.CustomString},
                public?: true

              attribute :event_filters, AshHooks.OutboxMatching.CustomMap, public?: true
              attribute :paused, AshHooks.OutboxMatching.CustomBoolean, default: false

            :strings ->
              :ok

            :nullable_pause ->
              attribute :paused, :boolean, public?: true
          end
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        actions do
          read :read do
            primary? true
            pagination offset?: true, required?: true, default_limit: 3
            prepare AshHooks.OutboxMatching.Preparation
          end
        end

        subscription do
          endpoint_resource AshHooks.OutboxFixtures.SQLite.Endpoint
          filter_attributes [:region, :flag, :count, :nested, :__invalid__]
          pausable :on
        end
      end

      defmodule unquote(emitter) do
        use Ash.Resource,
          domain: AshHooks.OutboxMatching.Domain,
          data_layer: Ash.DataLayer.Simple,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
          attribute :org_id, :string, allow_nil?: false
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        webhooks do
          outbound :changed do
            subscriptions unquote(subscription)
            deliveries AshHooks.OutboxFixtures.SQLite.Delivery
          end
        end
      end
    end
  )
end

for {namespace, layer, repo, table} <- [
      {AshHooks.OutboxFixtures.SQLite, AshSqlite.DataLayer, AshHooks.OutboxFixtures.SQLiteRepo,
       "outbox_sqlite_subscriptions"},
      {AshHooks.OutboxFixtures.Postgres, AshPostgres.DataLayer,
       AshHooks.OutboxFixtures.Postgres.Repo, "outbox_postgres_subscriptions"}
    ] do
  subscription = Module.concat(namespace, :NullableSubscription)
  emitter = Module.concat(namespace, :NullableEmitter)
  endpoint = Module.concat(namespace, :Endpoint)
  delivery = Module.concat(namespace, :Delivery)
  path = if layer == AshSqlite.DataLayer, do: :sqlite, else: :postgres

  configuration =
    {path, [],
     [
       [
         do:
           quote do
             table(unquote(table))
             repo(unquote(repo))
           end
       ]
     ]}

  Code.eval_quoted(
    quote do
      defmodule unquote(subscription) do
        use Ash.Resource,
          domain: AshHooks.OutboxMatching.Domain,
          data_layer: unquote(layer),
          extensions: [AshHooks.Subscription]

        unquote(configuration)

        attributes do
          attribute :org_id, :string, allow_nil?: false
          attribute :paused, :boolean, public?: true
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        actions do
          defaults [:read]
        end

        subscription do
          endpoint_resource unquote(endpoint)
          filter_attributes [:region]
          pausable :on
        end
      end

      defmodule unquote(emitter) do
        use Ash.Resource,
          domain: AshHooks.OutboxMatching.Domain,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          outbound :changed do
            subscriptions unquote(subscription)
            deliveries unquote(delivery)
          end
        end
      end
    end
  )
end

defmodule AshHooks.OutboxMatching.Outbox do
  use Ash.Resource,
    domain: AshHooks.OutboxMatching.Domain,
    data_layer: AshSqlite.DataLayer,
    extensions: [AshHooks.OutboundOutbox]

  sqlite do
    table "outbox_sqlite_publications"
    repo(AshHooks.OutboxFixtures.SQLiteRepo)
  end

  attributes do
    attribute :org_id, :string, allow_nil?: false
  end

  multitenancy do
    strategy :attribute
    attribute :org_id
  end

  actions do
    defaults [:read]
  end

  outbox do
    declarations [
      {AshHooks.OutboxMatching.EtsStrings.Emitter, :changed},
      {AshHooks.OutboxMatching.EtsAtoms.Emitter, :changed},
      {AshHooks.OutboxMatching.SimpleStrings.Emitter, :changed},
      {AshHooks.OutboxMatching.SimpleAtoms.Emitter, :changed},
      {AshHooks.OutboxMatching.EtsOpenAtoms.Emitter, :changed},
      {AshHooks.OutboxMatching.SimpleOpenAtoms.Emitter, :changed},
      {AshHooks.OutboxMatching.EtsCustom.Emitter, :changed},
      {AshHooks.OutboxMatching.SimpleCustom.Emitter, :changed},
      {AshHooks.OutboxMatching.EtsEmptyAtoms.Emitter, :changed},
      {AshHooks.OutboxMatching.SimpleEmptyAtoms.Emitter, :changed},
      {AshHooks.OutboxMatching.EtsNullablePause.Emitter, :changed},
      {AshHooks.OutboxMatching.SimpleNullablePause.Emitter, :changed},
      {AshHooks.OutboxFixtures.SQLite.NullableEmitter, :changed},
      {AshHooks.OutboxFixtures.Postgres.NullableEmitter, :changed}
    ]

    delivery_routes default: nil
    deduplication_horizon_seconds 3600
  end
end

defmodule AshHooks.OutboxMatching.Domain do
  use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

  resources do
    resource AshHooks.OutboxMatching.EtsStrings.Subscription
    resource AshHooks.OutboxMatching.EtsStrings.Emitter
    resource AshHooks.OutboxMatching.EtsAtoms.Subscription
    resource AshHooks.OutboxMatching.EtsAtoms.Emitter
    resource AshHooks.OutboxMatching.SimpleStrings.Subscription
    resource AshHooks.OutboxMatching.SimpleStrings.Emitter
    resource AshHooks.OutboxMatching.SimpleAtoms.Subscription
    resource AshHooks.OutboxMatching.SimpleAtoms.Emitter
    resource AshHooks.OutboxMatching.EtsOpenAtoms.Subscription
    resource AshHooks.OutboxMatching.EtsOpenAtoms.Emitter
    resource AshHooks.OutboxMatching.SimpleOpenAtoms.Subscription
    resource AshHooks.OutboxMatching.SimpleOpenAtoms.Emitter
    resource AshHooks.OutboxMatching.EtsCustom.Subscription
    resource AshHooks.OutboxMatching.EtsCustom.Emitter
    resource AshHooks.OutboxMatching.SimpleCustom.Subscription
    resource AshHooks.OutboxMatching.SimpleCustom.Emitter
    resource AshHooks.OutboxMatching.EtsEmptyAtoms.Subscription
    resource AshHooks.OutboxMatching.EtsEmptyAtoms.Emitter
    resource AshHooks.OutboxMatching.SimpleEmptyAtoms.Subscription
    resource AshHooks.OutboxMatching.SimpleEmptyAtoms.Emitter
    resource AshHooks.OutboxMatching.EtsNullablePause.Subscription
    resource AshHooks.OutboxMatching.EtsNullablePause.Emitter
    resource AshHooks.OutboxMatching.SimpleNullablePause.Subscription
    resource AshHooks.OutboxMatching.SimpleNullablePause.Emitter
    resource AshHooks.OutboxFixtures.SQLite.NullableSubscription
    resource AshHooks.OutboxFixtures.SQLite.NullableEmitter
    resource AshHooks.OutboxFixtures.Postgres.NullableSubscription
    resource AshHooks.OutboxFixtures.Postgres.NullableEmitter
    resource AshHooks.OutboxMatching.Outbox
  end
end

defmodule AshHooks.OutboxMatchingTest do
  use ExUnit.Case, async: false
  alias Ash.DataLayer.Ets
  alias AshHooks.OutboxAcceptance, as: Cases

  setup_all do
    {:ok, Cases.setup(AshHooks.OutboxFixtures.SQLite)}
  end

  setup context do
    Cases.clean(context)
  end

  for name <- [
        :EtsStrings,
        :EtsAtoms,
        :SimpleStrings,
        :SimpleAtoms,
        :EtsOpenAtoms,
        :SimpleOpenAtoms,
        :EtsCustom,
        :SimpleCustom,
        :EtsEmptyAtoms,
        :SimpleEmptyAtoms,
        :EtsNullablePause,
        :SimpleNullablePause
      ] do
    @tag name: name
    test "A12 production reads retain pagination and exact in-memory matching for #{name}", f do
      name = f.name
      subscription = Module.concat([AshHooks.OutboxMatching, name, Subscription])
      emitter = Module.concat([AshHooks.OutboxMatching, name, Emitter])
      empty? = name in [:EtsEmptyAtoms, :SimpleEmptyAtoms]
      atoms? = empty? or name in [:EtsAtoms, :SimpleAtoms, :EtsOpenAtoms, :SimpleOpenAtoms]
      types = if empty?, do: [:other], else: if(atoms?, do: [:changed], else: ["changed"])
      widened? = name in [:EtsOpenAtoms, :SimpleOpenAtoms, :EtsCustom, :SimpleCustom]
      nullable_pause? = name in [:EtsNullablePause, :SimpleNullablePause]
      widened? = widened? or nullable_pause?
      ets? = Ash.DataLayer.data_layer(subscription) == Ets
      endpoint = Cases.endpoint(f)

      filters = [
        nil,
        %{},
        %{"region" => "west"},
        %{"region" => ["west", "south"]},
        %{"region" => "east"},
        %{"flag" => true},
        %{"count" => 1},
        %{"nested" => %{"value" => true}},
        %{"missing" => nil}
      ]

      filters = if ets?, do: filters, else: filters ++ [[], "malformed", true, 42]

      rows =
        Enum.map(filters, fn filters ->
          struct(subscription,
            id: Ash.UUID.generate(),
            org_id: "tenant-a",
            event_types: types,
            paused: false,
            endpoint_id: endpoint.id,
            event_filters: filters
          )
        end)

      rows =
        rows ++
          [
            struct(subscription,
              id: Ash.UUID.generate(),
              org_id: "tenant-a",
              event_types: if(atoms?, do: [:other], else: ["other"]),
              paused: false,
              endpoint_id: endpoint.id,
              event_filters: nil
            )
          ]

      rows =
        rows ++
          [
            struct(subscription,
              id: Ash.UUID.generate(),
              org_id: "tenant-a",
              event_types: if(empty?, do: [:other], else: if(atoms?, do: [:*], else: ["*"])),
              paused: true,
              endpoint_id: endpoint.id,
              event_filters: nil
            )
          ]

      Application.put_env(:ash_hooks, subscription, {self(), rows})

      on_exit(fn ->
        Application.delete_env(:ash_hooks, subscription)
        if ets?, do: Ets.stop(subscription)
      end)

      if ets? do
        for row <- rows,
            do: assert({:ok, _} = Ets.create(subscription, Ash.Changeset.new(row)))
      end

      metadata = %{
        "region" => "west",
        "flag" => true,
        "count" => 1.0,
        "nested" => %{"value" => true},
        "__invalid__" => true
      }

      event = Cases.event(Ash.UUID.generate(), metadata)

      expected =
        rows
        |> Enum.filter(fn row ->
          not row.paused and AshHooks.Subscription.matches?(row, event.type) and
            AshHooks.Subscription.matches_filters?(row, metadata)
        end)
        |> Enum.map(& &1.id)
        |> Enum.sort()

      assert {:ok, results} = AshHooks.dispatch(emitter, :changed, event, tenant: "tenant-a")
      assert length(results) == if(empty?, do: 0, else: 1)
      candidates = selected(subscription, [])
      assert MapSet.subset?(MapSet.new(expected), MapSet.new(candidates))
      unless widened?, do: assert(candidates == expected)

      assert {:ok, :accepted} =
               AshHooks.publish(AshHooks.OutboxMatching.Outbox, {emitter, :changed}, event,
                 tenant: "tenant-a"
               )

      other = if name == :EtsStrings, do: :EtsAtoms, else: :EtsStrings
      other_emitter = Module.concat([AshHooks.OutboxMatching, other, Emitter])

      assert {:error, :publication_conflict} =
               AshHooks.publish(AshHooks.OutboxMatching.Outbox, {other_emitter, :changed}, event,
                 tenant: "tenant-a"
               )

      assert :done = AshHooks.fanout(AshHooks.OutboxMatching.Outbox, event.id, tenant: "tenant-a")
      candidates = selected(subscription, [])
      assert MapSet.subset?(MapSet.new(expected), MapSet.new(candidates))
      unless widened?, do: assert(candidates == expected)
      assert length(Cases.rows(f, :delivery)) == if(empty?, do: 0, else: 1)
    end
  end

  defp selected(resource, acc) do
    receive do
      {:selected, ^resource, ids} -> selected(resource, acc ++ ids)
    after
      0 -> Enum.sort(acc)
    end
  end
end

for {test_module, namespace} <- [
      {AshHooks.OutboxNullableSQLiteTest, AshHooks.OutboxFixtures.SQLite},
      {AshHooks.OutboxNullablePostgresTest, AshHooks.OutboxFixtures.Postgres}
    ] do
  defmodule test_module do
    use ExUnit.Case, async: false
    alias AshHooks.OutboxAcceptance, as: Cases
    @namespace namespace
    if @namespace == AshHooks.OutboxFixtures.Postgres, do: @moduletag(:postgres)

    setup_all do
      if @namespace == AshHooks.OutboxFixtures.Postgres,
        do: Cases.setup(AshHooks.OutboxFixtures.SQLite)

      {:ok, Cases.setup(@namespace)}
    end

    test "A12 nullable host pause declarations retain Boolean matching in both paths", f do
      Cases.endpoint(f)
      emitter = Module.concat(@namespace, :NullableEmitter)
      event = Cases.event()

      assert {:ok, [%{status: :deferred}]} =
               AshHooks.dispatch(emitter, :changed, event, tenant: "tenant-a")

      outbox = AshHooks.OutboxMatching.Outbox

      assert {:ok, :accepted} =
               AshHooks.publish(outbox, {emitter, :changed}, event, tenant: "tenant-a")

      assert :done = AshHooks.fanout(outbox, event.id, tenant: "tenant-a")
      assert length(Cases.rows(f, :delivery)) == 1
    end
  end
end
