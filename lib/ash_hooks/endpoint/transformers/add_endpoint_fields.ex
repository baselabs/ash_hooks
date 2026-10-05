defmodule AshHooks.Endpoint.Transformers.AddEndpointFields do
  @moduledoc false
  # Injects the endpoint attributes and a client-writable uuid primary key
  # when the resource declares none (the inbound-ledger transformer's
  # pattern: the dispatcher identifies rows by the same key shape).
  #
  # `status_attribute` maps the durable enable/disable onto the consumer's
  # OWN attribute (H4): the injected `status` is then NOT injected — one
  # switch, so the consumer's off switch and the package's can never
  # silently disagree. The mapping fails closed at compile: the attribute
  # must exist and must not collide with another injected field.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.{Extension, Transformer}
  alias Spark.Error.DslError

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, status_attribute} <- check_status_attribute(dsl_state),
         {:ok, dsl_state} <- add_primary_key(dsl_state) do
      add_attributes(dsl_state, status_attribute)
    end
  end

  defp check_status_attribute(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :resource)

    status_attribute = Extension.get_opt(dsl_state, [:endpoint], :status_attribute, nil)
    enabled_values = Extension.get_opt(dsl_state, [:endpoint], :enabled_values, nil)
    disabled_value = Extension.get_opt(dsl_state, [:endpoint], :disabled_value, nil)

    attributes =
      dsl_state |> Transformer.get_entities([:attributes]) |> Map.new(&{&1.name, &1})

    reserved = Enum.map(attributes_spec(), &elem(&1, 0)) -- [:status]

    cond do
      is_nil(status_attribute) ->
        {:ok, nil}

      status_attribute in [:id | reserved] ->
        {:error,
         DslError.exception(
           module: resource,
           path: [:endpoint, :status_attribute],
           message:
             "status_attribute #{inspect(status_attribute)} collides with the primary key or an injected endpoint field — the switch cannot replace the pk, the url, or a secret ref"
         )}

      not Map.has_key?(attributes, status_attribute) ->
        # the attribute must be the CONSUMER'S OWN declaration (the
        # `attributes` block): an attribute another extension injects may
        # not exist yet at this transformer (Spark's order across
        # extensions is not declaration order), and the mapping's
        # correctness is the consumer's declaration, not an injection's
        {:error,
         DslError.exception(
           module: resource,
           path: [:endpoint, :status_attribute],
           message:
             "status_attribute #{inspect(status_attribute)} is not an attribute declared on this resource — declare it under your own `attributes` block (it is the durable enable/disable switch, H4)"
         )}

      is_nil(enabled_values) or is_nil(disabled_value) ->
        # both ends of the mapping must be spelled out: a defaulted
        # `[:enabled]`/`:disabled` against a boolean or custom-enum switch
        # matches NOTHING — zero deliveries, no error (the H8 failure
        # class, fail-closed at compile instead)
        {:error,
         DslError.exception(
           module: resource,
           path: [:endpoint],
           message:
             "status_attribute #{inspect(status_attribute)} requires explicit enabled_values and disabled_value — a defaulted mapping silently matches no row value and delivers nothing"
         )}

      disabled_value in enabled_values ->
        # a disable that lands INSIDE enabled_values leaves the endpoint
        # deliverable — the 410 breaker would write a no-op
        {:error,
         DslError.exception(
           module: resource,
           path: [:endpoint],
           message:
             "disabled_value #{inspect(disabled_value)} is inside enabled_values — the durable disable must leave the endpoint non-deliverable"
         )}

      true ->
        {:ok, status_attribute}
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

  defp add_attributes(dsl_state, nil),
    do: inject(dsl_state, attributes_spec())

  # a mapped switch means the injected :status attribute STAYS OUT — the
  # consumer's own attribute (any type: boolean, enum, ...) governs
  # delivery, exactly one switch (H4)
  defp add_attributes(dsl_state, _mapped),
    do: inject(dsl_state, mapped_attributes_spec())

  defp inject(dsl_state, spec) do
    Enum.reduce_while(spec, {:ok, dsl_state}, fn {name, type, opts}, {:ok, dsl_state} ->
      {:cont, Builder.add_new_attribute(dsl_state, name, type, opts)}
    end)
  end

  defp attributes_spec do
    [
      {:url, AshHooks.Endpoint.Url, [allow_nil?: false, public?: true]},
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

  defp mapped_attributes_spec, do: List.keydelete(attributes_spec(), :status, 0)
end
