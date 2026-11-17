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

for {name, layer, atoms?} <- [
      {:EtsStrings, Ash.DataLayer.Ets, false},
      {:EtsAtoms, Ash.DataLayer.Ets, true},
      {:SimpleStrings, Ash.DataLayer.Simple, false},
      {:SimpleAtoms, Ash.DataLayer.Simple, true}
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

          if unquote(atoms?) do
            attribute :event_types, {:array, :atom},
              public?: true,
              constraints: [items: [one_of: [:changed, :other, :*]]]
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
      {AshHooks.OutboxMatching.SimpleAtoms.Emitter, :changed}
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

  for name <- [:EtsStrings, :EtsAtoms, :SimpleStrings, :SimpleAtoms] do
    @tag name: name
    test "A12 production reads retain pagination and exact in-memory matching for #{name}", f do
      name = f.name
      subscription = Module.concat([AshHooks.OutboxMatching, name, Subscription])
      emitter = Module.concat([AshHooks.OutboxMatching, name, Emitter])
      atoms? = name in [:EtsAtoms, :SimpleAtoms]
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
            event_types: if(atoms?, do: [:changed], else: ["changed"]),
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
              event_types: if(atoms?, do: [:*], else: ["*"]),
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

      assert {:ok, [_result]} = AshHooks.dispatch(emitter, :changed, event, tenant: "tenant-a")
      assert selected(subscription, []) == expected

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
      assert selected(subscription, []) == expected
      assert length(Cases.rows(f, :delivery)) == 1
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
