defmodule AshHooks.Endpoint.Transformers.AddEndpointFields do
  @moduledoc false
  # Injects the endpoint attributes and a client-writable uuid primary key
  # when the resource declares none (the inbound-ledger transformer's
  # pattern: the dispatcher identifies rows by the same key shape).
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
      {:url, :string, [allow_nil?: false, public?: true]},
      {:status, :atom,
       [
         allow_nil?: false,
         default: :enabled,
         public?: true,
         constraints: [one_of: AshHooks.Endpoint.statuses()]
       ]},
      {:secret_ref, AshHooks.Endpoint.SecretRef, [allow_nil?: false, public?: true]},
      {:previous_secret_ref, AshHooks.Endpoint.SecretRef, [public?: true]},
      {:legacy_secret_ref, AshHooks.Endpoint.SecretRef, [public?: true]},
      {:legacy_previous_secret_ref, AshHooks.Endpoint.SecretRef, [public?: true]}
    ]
  end
end
