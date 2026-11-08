defmodule AshHooks.OutboundEvent.Transformers.AddEventFields do
  @moduledoc false
  # Injects the event-log attributes and a client-writable uuid primary
  # key when the resource declares none (the ledger pattern).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.Transformer

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, dsl_state} <- add_primary_key(dsl_state) do
      Enum.reduce_while(attributes_spec(), {:ok, dsl_state}, fn {name, type, opts},
                                                                {:ok, dsl_state} ->
        {:cont, Builder.add_new_attribute(dsl_state, name, type, opts)}
      end)
    end
  end

  defp add_primary_key(dsl_state) do
    has_pk? =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Enum.any?(& &1.primary_key?)

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
      {:event_uuid, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:event_type, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:version, :integer, [constraints: [min: 1]]},
      {:payload, :binary, [allow_nil?: false]}
    ]
  end
end
