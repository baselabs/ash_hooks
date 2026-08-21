defmodule AshHooks.InboundDelivery.Transformers.AddLedgerFields do
  @moduledoc false
  # Injects the ledger attributes (and a client-writable uuid primary key
  # when the resource declares none — created/duplicate classification
  # compares the surviving row's id against the caller-generated one).
  #
  # Also fail-closes on scope slots before anything consumes them: each
  # declared slot must exist as a non-nullable attribute. A nullable slot
  # would make nil scope values distinct on SQL unique indexes and silently
  # break dedup for scope-less redeliveries.
  use Spark.Dsl.Transformer

  alias Ash.Resource.Builder
  alias AshHooks.InboundDelivery
  alias Spark.Dsl.{Extension, Transformer}
  alias Spark.Error.DslError

  def before?(Ash.Resource.Transformers.DefaultAccept), do: true
  def before?(Ash.Resource.Transformers.CachePrimaryKey), do: true
  def before?(Ash.Resource.Transformers.AttributesByName), do: true
  def before?(_), do: false

  def transform(dsl_state) do
    with :ok <- check_scope_slots(dsl_state),
         {:ok, dsl_state} <- add_primary_key(dsl_state) do
      add_attributes(dsl_state)
    end
  end

  defp check_scope_slots(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :resource)

    scope = Extension.get_opt(dsl_state, [:inbound_delivery], :scope_identity, [])

    attributes =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Map.new(&{&1.name, &1})

    Enum.reduce_while(scope, :ok, fn slot, :ok ->
      attribute = attributes[slot]

      cond do
        is_nil(attribute) ->
          {:halt,
           {:error,
            DslError.exception(
              module: resource,
              path: [:inbound_delivery, :scope_identity],
              message:
                "scope_identity slot #{inspect(slot)} is not an attribute on this resource — declare it under `attributes` (it participates in the unique_ingest identity)"
            )}}

        attribute.allow_nil? ->
          {:halt,
           {:error,
            DslError.exception(
              module: resource,
              path: [:inbound_delivery, :scope_identity],
              message:
                "scope_identity slot #{inspect(slot)} must be allow_nil?: false — a nullable slot makes nil scope values distinct on SQL unique indexes and silently breaks redelivery dedup"
            )}}

        true ->
          {:cont, :ok}
      end
    end)
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
    attributes = [
      {:provider, :atom, [allow_nil?: false]},
      {:external_event_id, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:external_event_type, :string, []},
      {:payload, :map, [allow_nil?: false]},
      {:payload_digest, :string, [allow_nil?: false]},
      {:status, :atom,
       [
         allow_nil?: false,
         default: :received,
         constraints: [one_of: InboundDelivery.statuses()]
       ]},
      {:fencing_token, :integer, [allow_nil?: false, default: 0]},
      {:lease_expires_at, :utc_datetime_usec, []},
      {:error_class, :string, []},
      {:attempts, :integer, [allow_nil?: false, default: 0]}
    ]

    Enum.reduce_while(attributes, {:ok, dsl_state}, fn {name, type, opts}, {:ok, dsl_state} ->
      case Builder.add_new_attribute(dsl_state, name, type, opts) do
        {:ok, dsl_state} -> {:cont, {:ok, dsl_state}}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
