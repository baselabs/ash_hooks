defmodule AshHooks.Subscription.Transformers.AddSubscriptionFields do
  @moduledoc false
  # Injects the subscription attributes and a client-writable uuid primary
  # key when the resource declares none.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.{Extension, Transformer}

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(state) do
    with {:ok, state} <- add_primary_key(state) do
      Enum.reduce(attributes_spec(state), {:ok, state}, fn {name, type, opts}, result ->
        Builder.add_new_attribute(result, name, type, opts)
      end)
    end
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
