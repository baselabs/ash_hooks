defmodule AshHooks.OutboundOutbox.Transformers.AddOutbox do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Ash.Resource.Change.Builtins
  alias Spark.Dsl.{Extension, Transformer}

  require Ash.Expr

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CacheActionInputs), do: true
  def before?(Ash.Resource.Transformers.SetPrimaryActions), do: true
  def before?(Ash.Resource.Transformers.RequireUniqueActionNames), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(Ash.Resource.Transformers.SetPreCheckWith), do: true
  def before?(Ash.Resource.Transformers.CacheUniqueKeys), do: true
  def before?(Ash.Resource.Transformers.SetEagerCheckWith), do: true
  def before?(_), do: false

  def transform(state) do
    state = metadata_storage(state)

    with {:ok, state} <- fields(state),
         {:ok, state} <- identity(state) do
      state = indexes(state)

      Enum.reduce_while(actions(state), {:ok, state}, &add_action/2)
    end
  end

  defp add_action({type, name, opts}, {:ok, state}) do
    case Builder.build_action(type, name, opts) do
      {:ok, action} -> {:cont, {:ok, Transformer.add_entity(state, [:actions], action)}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  # PostgreSQL json preserves number kinds in the JSON text. jsonb normalizes
  # 1.0e20 into an integer, which would change strict membership after recovery.
  defp metadata_storage(state) do
    if Transformer.get_persisted(state, :data_layer) == AshPostgres.DataLayer do
      types = Extension.get_opt(state, [:postgres], :migration_types, [])

      Transformer.set_option(
        state,
        [:postgres],
        :migration_types,
        Keyword.put_new(types, :metadata, :json)
      )
    else
      state
    end
  end

  defp fields(state) do
    specs = [
      {:id, :uuid, [primary_key?: true, allow_nil?: false, default: &Ash.UUID.generate/0]},
      {:event_uuid, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:event_type, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:version, :integer, [allow_nil?: false, constraints: [min: 1]]},
      {:payload, :binary, [allow_nil?: false]},
      {:metadata, :map, [allow_nil?: false, default: %{}]},
      {:format_version, :integer, [allow_nil?: false, default: 1]},
      {:dispatch_source, :string, [allow_nil?: false]},
      {:dispatch_route, :string, [allow_nil?: false]},
      {:acceptance_token, :uuid, [allow_nil?: false]},
      {:state, :atom,
       [allow_nil?: false, default: :pending, constraints: [one_of: [:pending, :done, :failed]]]},
      {:claim_token, :uuid, []},
      {:lease_expires_at, :utc_datetime_usec, []},
      {:attempts, :integer, [allow_nil?: false, default: 0]},
      {:next_attempt_at, :utc_datetime_usec, [allow_nil?: false, default: &DateTime.utc_now/0]},
      {:last_error, :string, [constraints: [max_length: 255]]},
      {:completed_at, :utc_datetime_usec, []},
      {:failed_at, :utc_datetime_usec, []},
      {:inserted_at, :utc_datetime_usec, [allow_nil?: false, default: &DateTime.utc_now/0]},
      {:updated_at, :utc_datetime_usec,
       [allow_nil?: false, default: &DateTime.utc_now/0, update_default: &DateTime.utc_now/0]}
    ]

    Enum.reduce_while(specs, {:ok, state}, fn {name, type, opts}, {:ok, state} ->
      case Builder.add_new_attribute(state, name, type, Keyword.put(opts, :public?, true)) do
        {:ok, state} -> {:cont, {:ok, state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp identity(state) do
    tenant = Transformer.get_option(state, [:multitenancy], :attribute)

    Builder.add_new_identity(
      state,
      :unique_publication,
      Enum.reject([tenant, :event_uuid], &is_nil/1)
    )
  end

  defp indexes(state) do
    layer = Transformer.get_persisted(state, :data_layer)

    path =
      case layer do
        AshPostgres.DataLayer -> [:postgres, :custom_indexes]
        AshSqlite.DataLayer -> [:sqlite, :custom_indexes]
        _other -> []
      end

    if path == [] do
      state
    else
      tenant = Transformer.get_option(state, [:multitenancy], :attribute)
      attributes = Transformer.get_entities(state, [:attributes])

      source = fn name ->
        attribute = Enum.find(attributes, &(&1.name == name))
        attribute.source || attribute.name
      end

      state_column = source.(:state) |> to_string() |> String.replace("\"", "\"\"")

      Enum.reduce([next_attempt_at: :pending, failed_at: :failed], state, fn {field, status},
                                                                             state ->
        fields = [tenant, field] |> Enum.reject(&is_nil/1) |> Enum.map(source)
        where = "\"#{state_column}\" = '#{status}'"
        add_index(state, layer, path, fields, where)
      end)
    end
  end

  defp add_index(state, layer, path, fields, where) do
    if Enum.any?(
         Transformer.get_entities(state, path),
         &(&1.fields == fields and &1.where == where)
       ) do
      state
    else
      index = Transformer.build_entity!(layer, path, :index, fields: fields, where: where)
      Transformer.add_entity(state, path, index)
    end
  end

  defp actions(state) do
    horizon = Extension.get_opt(state, [:outbox], :deduplication_horizon_seconds)
    prune_filter = Ash.Expr.expr(state == :done and completed_at < ago(^horizon, :second))

    [
      {:create, :publish,
       [
         upsert?: true,
         upsert_identity: :unique_publication,
         upsert_fields: [],
         notifiers: [AshHooks.OutboundOutbox.Notifier],
         accept: [
           :event_uuid,
           :event_type,
           :version,
           :payload,
           :metadata,
           :format_version,
           :dispatch_source,
           :dispatch_route,
           :acceptance_token,
           :next_attempt_at
         ]
       ]},
      update(
        :claim,
        [claim_token: :uuid, lease_expires_at: :utc_datetime_usec],
        [increment(:attempts)],
        Ash.Expr.expr(
          state == :pending and (is_nil(next_attempt_at) or next_attempt_at <= now()) and
            (is_nil(lease_expires_at) or lease_expires_at <= now())
        )
      ),
      update(
        :finish,
        [claim_token: :uuid, completed_at: :utc_datetime_usec],
        [
          set(:state, :done),
          set(:last_error, nil),
          set(:claim_token, nil),
          set(:lease_expires_at, nil)
        ],
        live_filter()
      ),
      update(
        :release,
        [claim_token: :uuid, next_attempt_at: :utc_datetime_usec, last_error: :string],
        [set(:claim_token, nil), set(:lease_expires_at, nil)],
        live_filter()
      ),
      update(
        :park,
        [claim_token: :uuid, failed_at: :utc_datetime_usec, last_error: :string],
        [set(:state, :failed), set(:claim_token, nil), set(:lease_expires_at, nil)],
        live_filter()
      ),
      update(
        :rearm,
        [next_attempt_at: :utc_datetime_usec],
        [set(:state, :pending), set(:attempts, 0), set(:failed_at, nil), set(:last_error, nil)],
        Ash.Expr.expr(state == :failed)
      ),
      {:destroy, :prune, [accept: [], changes: [change(Builtins.filter(prune_filter))]]}
    ]
  end

  defp live_filter do
    Ash.Expr.expr(
      state == :pending and claim_token == ^Ash.Expr.arg(:claim_token) and
        lease_expires_at > now()
    )
  end

  defp update(name, args, changes, filter) do
    # Claim tokens fence transitions, but are not overwritten by finish/release/park.
    writes =
      if name in [:finish, :release, :park], do: Keyword.delete(args, :claim_token), else: args

    {:update, name,
     [
       accept: [],
       arguments: Enum.map(args, fn {name, type} -> argument(name, type) end),
       changes:
         [change(Builtins.filter(filter)) | changes] ++
           Enum.map(writes, fn {name, _} -> set(name, Ash.Expr.arg(name)) end)
     ]}
  end

  defp argument(name, type) do
    {:ok, argument} = Builder.build_action_argument(name, type, allow_nil?: false)
    argument
  end

  defp increment(name), do: change(Builtins.increment(name))
  defp set(name, value), do: change(Builtins.set_attribute(name, value))

  defp change(reference) do
    {:ok, change} = Builder.build_action_change(reference)
    change
  end
end
