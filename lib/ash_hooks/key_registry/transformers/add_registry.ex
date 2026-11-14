defmodule AshHooks.KeyRegistry.Transformers.AddRegistry do
  @moduledoc false
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(transformer),
    do:
      transformer in [
        Ash.Resource.Transformers.DefaultAccept,
        Ash.Resource.Transformers.CachePrimaryKey,
        Ash.Resource.Transformers.AttributesByName,
        Ash.Resource.Transformers.CacheActionInputs,
        Ash.Resource.Transformers.SetPrimaryActions,
        Ash.Resource.Transformers.RequireUniqueActionNames
      ]

  def transform(state) do
    state =
      Enum.reduce(attributes(), state, fn {name, type, options}, state ->
        {:ok, state} = Builder.add_new_attribute(state, name, type, options)
        state
      end)

    {:ok, pagination} = Builder.build_pagination(keyset?: true, required?: false)

    actions = [
      {:read, :read, [primary?: true, pagination: pagination]},
      {:create, :issue_key, [accept: Enum.map(attributes(), &elem(&1, 0))]},
      {:update, :transition_key,
       [
         accept: [
           :state,
           :owner_resource,
           :owner_key,
           :destroy_after,
           :attempts,
           :next_attempt_at,
           :destroy_generation,
           :last_error,
           :updated_at
         ]
       ]},
      {:destroy, :prune_keys, []}
    ]

    state =
      Enum.reduce(actions, state, fn {type, name, options}, state ->
        if name in Transformer.get_option(state, [:actions], :defaults, []) or
             Enum.any?(Transformer.get_entities(state, [:actions]), &(&1.name == name)) do
          state
        else
          {:ok, action} = Builder.build_action(type, name, options)
          Transformer.add_entity(state, [:actions], action)
        end
      end)

    {:ok, state}
  end

  defp attributes do
    [
      {:ref, :string, [primary_key?: true, allow_nil?: false, constraints: [max_length: 40]]},
      {:kind, :term, [allow_nil?: false]},
      {:owner_resource, :atom, [allow_nil?: false]},
      {:owner_key, :map, []},
      {:state, :atom,
       [
         allow_nil?: false,
         default: :issued,
         constraints: [one_of: [:issued, :attached, :retired, :destroy_failed, :destroyed]]
       ]},
      {:custody_tenant, :string, []},
      {:issued_at, :utc_datetime_usec, [allow_nil?: false]},
      {:destroy_after, :utc_datetime_usec, []},
      {:attempts, :integer, [allow_nil?: false, default: 0, constraints: [min: 0]]},
      {:next_attempt_at, :utc_datetime_usec, []},
      {:destroy_generation, :integer, [allow_nil?: false, default: 0, constraints: [min: 0]]},
      {:last_error, :string, [constraints: [max_length: 64]]},
      {:inserted_at, :utc_datetime_usec, [allow_nil?: false, default: &DateTime.utc_now/0]},
      {:updated_at, :utc_datetime_usec, [allow_nil?: false, default: &DateTime.utc_now/0]}
    ]
  end
end
