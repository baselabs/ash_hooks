defmodule AshHooks.Subscription.Transformers.AddSubscriptionFields do
  @moduledoc false
  # Injects the subscription attributes and a client-writable uuid primary
  # key when the resource declares none.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, dsl_state} <- add_primary_key(dsl_state) do
      add_attributes(dsl_state)
    end
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

  defp add_attributes(dsl_state) do
    Enum.reduce_while(attributes_spec(), {:ok, dsl_state}, fn {name, type, opts},
                                                              {:ok, dsl_state} ->
      case Builder.add_new_attribute(dsl_state, name, type, opts) do
        {:ok, dsl_state} -> {:cont, {:ok, dsl_state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
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
