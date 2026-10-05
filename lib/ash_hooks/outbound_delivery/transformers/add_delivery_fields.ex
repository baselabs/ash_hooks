defmodule AshHooks.OutboundDelivery.Transformers.AddDeliveryFields do
  @moduledoc false
  # Injects the delivery-ledger attributes and a client-writable uuid
  # primary key when the resource declares none (created/duplicate
  # classification compares the surviving row's id, the ingest pattern).
  #
  # The exact-bytes column's name is configurable (`payload_attribute`,
  # default :payload) for consumers whose domain reserves `payload` for
  # its own sole store; the rename is fail-closed against the other
  # injected field names (a colliding rename would let ledger bytes
  # overwrite an identity or machine field).
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias Spark.Dsl.{Extension, Transformer}
  alias Spark.Error.DslError

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with {:ok, payload_attribute} <- check_payload_attribute(dsl_state),
         {:ok, dsl_state} <- add_primary_key(dsl_state) do
      add_attributes(dsl_state, payload_attribute)
    end
  end

  # The configured name replaces :payload in the injected spec; every
  # other spec name is reserved against it (the scope_identity pattern).
  defp check_payload_attribute(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :resource)

    payload_attribute =
      Extension.get_opt(dsl_state, [:outbound_delivery], :payload_attribute, :payload)

    reserved = Enum.map(attributes_spec(payload_attribute), &elem(&1, 0)) -- [payload_attribute]

    if payload_attribute in [:id | reserved] do
      {:error,
       DslError.exception(
         module: resource,
         path: [:outbound_delivery, :payload_attribute],
         message:
           "payload_attribute #{inspect(payload_attribute)} collides with an injected ledger field — the exact-bytes column cannot replace an identity or machine field"
       )}
    else
      {:ok, payload_attribute}
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

  defp add_attributes(dsl_state, payload_attribute) do
    Enum.reduce_while(attributes_spec(payload_attribute), {:ok, dsl_state}, fn {name, type, opts},
                                                                               {:ok, dsl_state} ->
      {:cont, Builder.add_new_attribute(dsl_state, name, type, opts)}
    end)
  end

  defp attributes_spec(payload_attribute) do
    [
      {:event_uuid, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:event_type, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {payload_attribute, :binary, [allow_nil?: false]},
      {:endpoint_id, :uuid, [allow_nil?: false]},
      {:subscription_id, :uuid, []},
      {:signing_mode, :atom, [constraints: [one_of: [:legacy, :dual, :standard]]]},
      {:status, :atom,
       [
         allow_nil?: false,
         default: :pending,
         constraints: [one_of: AshHooks.OutboundDelivery.statuses()]
       ]},
      {:attempts, :integer, [allow_nil?: false, default: 0]},
      {:response_status, :integer, [writable?: false]},
      {:response_snippet, :string, [writable?: false, constraints: [max_length: 2048]]},
      {:last_error, :string, [constraints: [max_length: 255]]},
      {:next_attempt_at, :utc_datetime_usec, [writable?: false]}
    ]
  end
end
