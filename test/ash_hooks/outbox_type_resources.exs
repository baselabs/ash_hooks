Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.OutboxTypeCases.String do
  use Ash.Type.NewType, subtype_of: :string
end

defmodule AshHooks.OutboxTypeCases.Atom do
  use Ash.Type.NewType, subtype_of: :atom
end

defmodule AshHooks.OutboxTypeCases.Term do
  use Ash.Type.NewType, subtype_of: :term
end

defmodule AshHooks.OutboxTypeCases do
  @moduledoc false
  alias Ash.Resource.Info

  def types do
    [
      {:Strings, {:array, :string}, []},
      {:ClosedAtoms, {:array, :atom}, [items: [one_of: [:changed, :other, :*]]]},
      {:OpenAtoms, {:array, :atom}, []},
      {:Terms, {:array, :term}, []},
      {:NewStrings, {:array, AshHooks.OutboxTypeCases.String}, []},
      {:NewAtoms, {:array, AshHooks.OutboxTypeCases.Atom}, []},
      {:NewTerms, {:array, AshHooks.OutboxTypeCases.Term}, []}
    ]
  end

  def cases do
    for {name, layer, namespace} <- [
          {:SQLite, AshSqlite.DataLayer, AshHooks.OutboxFixtures.SQLite},
          {:Postgres, AshPostgres.DataLayer, AshHooks.OutboxFixtures.Postgres},
          {:Ets, Ash.DataLayer.Ets, AshHooks.OutboxFixtures.SQLite},
          {:Simple, Ash.DataLayer.Simple, AshHooks.OutboxFixtures.SQLite}
        ],
        {shape, type, constraints} <- types(),
        not (layer == AshSqlite.DataLayer and shape in [:Terms, :NewTerms]) do
      prefix = Module.concat([__MODULE__, name, shape])

      %{
        layer: layer,
        namespace: namespace,
        shape: shape,
        type: type,
        constraints: constraints,
        subscription: Module.concat(prefix, Subscription),
        emitter: Module.concat(prefix, Emitter),
        table: "outbox_types_#{name}_#{shape}" |> String.downcase()
      }
    end
  end

  def declarations, do: Enum.map(cases(), &{&1.emitter, :changed})

  def create_table(f, resource) do
    table = AshHooks.OutboxAcceptance.table(resource)

    columns =
      Enum.map_join(Info.attributes(resource), ", ", fn attribute ->
        storage = Ash.Type.storage_type(attribute.type, attribute.constraints)

        "\"#{attribute.name}\" #{sql_type(storage, f.sqlite?)}" <>
          if(attribute.primary_key?, do: " PRIMARY KEY", else: "")
      end)

    f.owner.query!("CREATE TABLE #{table} (#{columns})")
    unless f.sqlite?, do: f.owner.query!("GRANT ALL ON #{table} TO #{f.roles.runtime}")
    ExUnit.Callbacks.on_exit(fn -> f.owner.query!("DROP TABLE #{table}") end)
  end

  defp sql_type({:array, _}, true), do: "TEXT"
  defp sql_type({:array, type}, false), do: sql_type(type, false) <> "[]"
  defp sql_type(:binary, true), do: "BLOB"
  defp sql_type(:binary, false), do: "BYTEA"
  defp sql_type(:uuid, false), do: "UUID"
  defp sql_type(:boolean, _), do: "BOOLEAN"
  defp sql_type(:map, false), do: "JSONB"
  defp sql_type(_, _), do: "TEXT"
end

for variant <- AshHooks.OutboxTypeCases.cases() do
  configuration =
    case variant.layer do
      AshSqlite.DataLayer ->
        quote do
          sqlite do
            table unquote(variant.table)
            repo(AshHooks.OutboxFixtures.SQLiteRepo)
          end
        end

      AshPostgres.DataLayer ->
        quote do
          postgres do
            table unquote(variant.table)
            repo(AshHooks.OutboxFixtures.Postgres.Repo)
          end
        end

      Ash.DataLayer.Ets ->
        quote do
          ets do
            private? false
          end
        end

      Ash.DataLayer.Simple ->
        nil
    end

  Code.eval_quoted(
    quote do
      defmodule unquote(variant.subscription) do
        use Ash.Resource,
          domain: AshHooks.OutboxMatching.Domain,
          data_layer: unquote(variant.layer),
          extensions: [AshHooks.Subscription]

        unquote(configuration)

        attributes do
          attribute :org_id, :string, allow_nil?: false

          attribute :event_types, unquote(Macro.escape(variant.type)),
            allow_nil?: true,
            public?: true,
            constraints: unquote(Macro.escape(variant.constraints))
        end

        multitenancy do
          strategy :attribute
          attribute :org_id
        end

        actions do
          defaults create: :*

          read :read do
            primary? true

            if unquote(variant.layer) == Ash.DataLayer.Simple,
              do: prepare(AshHooks.OutboxMatching.Preparation)
          end
        end

        subscription do
          endpoint_resource unquote(Module.concat(variant.namespace, Endpoint))
          pausable :on
          filter_attributes [:region]
        end
      end

      defmodule unquote(variant.emitter) do
        use Ash.Resource,
          domain: AshHooks.OutboxMatching.Domain,
          extensions: [AshHooks]

        attributes do
          uuid_primary_key :id
        end

        webhooks do
          outbound :changed do
            subscriptions unquote(variant.subscription)
            deliveries unquote(Module.concat(variant.namespace, Delivery))
          end
        end
      end
    end
  )
end

for {name, element} <- [
      {:PlainTerms, :term},
      {:PlainNewTerms, AshHooks.OutboxTypeCases.Term}
    ] do
  resource = Module.concat([AshHooks.OutboxTypeCases, SQLite, name])

  Code.eval_quoted(
    quote do
      defmodule unquote(resource) do
        use Ash.Resource,
          domain: AshHooks.OutboxMatching.Domain,
          data_layer: AshSqlite.DataLayer

        sqlite do
          table unquote("outbox_types_" <> String.downcase(to_string(name)))
          repo(AshHooks.OutboxFixtures.SQLiteRepo)
        end

        attributes do
          uuid_primary_key :id
          attribute :event_types, {:array, unquote(element)}, public?: true
        end

        actions do
          defaults create: :*
        end
      end
    end
  )
end
