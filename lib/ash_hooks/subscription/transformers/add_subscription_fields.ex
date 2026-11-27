defmodule AshHooks.Subscription.Transformers.AddSubscriptionFields do
  @moduledoc false
  # Injects the subscription attributes and a client-writable uuid primary
  # key when the resource declares none.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshHooks.Subscription.Validations.EventFilters
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(state) do
    with {:ok, state} <- add_primary_key(state),
         {:ok, state} <- add_attributes(state) do
      add_filter_validation(state)
    end
  end

  defp add_attributes(state) do
    Enum.reduce(attributes_spec(state), {:ok, state}, fn {name, type, opts}, result ->
      Builder.add_new_attribute(result, name, type, opts)
    end)
  end

  defp add_filter_validation(state) do
    if Extension.get_opt(state, [:subscription], :filter_attributes, []) == [] do
      {:ok, state}
    else
      # Create defaults and before-action changes can supply a filter after
      # changeset preparation, so validate again before the insert.
      with {:ok, validation} <- build_filter_validation(on: [:create, :update]),
           {:ok, before_create} <-
             build_filter_validation(on: [:create], before_action?: true) do
        state =
          state
          |> Transformer.add_entity([:validations], validation, type: :append)
          |> Transformer.add_entity([:validations], before_create, type: :append)
          |> validate_actions_skipping_globals(%{
            create: [validation, before_create],
            update: [validation]
          })

        {:ok, state}
      end
    end
  end

  defp build_filter_validation(opts) do
    Transformer.build_entity(
      Ash.Resource.Dsl,
      [:validations],
      :validate,
      Keyword.put(opts, :validation, EventFilters)
    )
  end

  defp validate_actions_skipping_globals(state, validations) do
    actions =
      for %{type: type, skip_global_validations?: true} = action <-
            Transformer.get_entities(state, [:actions]),
          action_validations = validations[type],
          do: %{action | changes: action.changes ++ action_validations}

    Enum.reduce(actions, state, fn action, state ->
      Transformer.replace_entity(state, [:actions], action, &(&1.name == action.name))
    end)
  end

  def attributes_spec(state) do
    filters =
      if Extension.get_opt(state, [:subscription], :filter_attributes, []) == [],
        do: [],
        else: [{:event_filters, :map, [public?: true]}]

    pause =
      if Extension.get_opt(state, [:subscription], :pausable, :off) == :on,
        do: [{:paused, :boolean, [allow_nil?: false, default: false, public?: true]}],
        else: []

    filters ++ pause ++ attributes_spec()
  end

  defp add_primary_key(dsl_state) do
    has_pk? =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(&(&1.primary_key? == true))

    if has_pk? do
      {:ok, dsl_state}
    else
      Builder.add_new_attribute(dsl_state, :id, :uuid,
        primary_key?: true,
        writable?: true,
        allow_nil?: false,
        default: &Ash.UUID.generate/0
      )
    end
  end

  defp attributes_spec do
    [
      {:event_types, {:array, :string}, [allow_nil?: false, default: ["*"], public?: true]},
      {:endpoint_id, :uuid, [allow_nil?: false, public?: true]},
      {:signing_mode, :atom,
       [public?: true, constraints: [one_of: AshHooks.Subscription.signing_modes()]]}
    ]
  end
end
