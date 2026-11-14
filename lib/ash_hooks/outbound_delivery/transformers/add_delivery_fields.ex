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
         {:ok, dsl_state} <- add_primary_key(dsl_state),
         {:ok, dsl_state} <- add_attributes(dsl_state, payload_attribute),
         {:ok, dsl_state} <- add_resend_attributes(dsl_state),
         {:ok, dsl_state} <- add_test_attributes(dsl_state),
         :ok <- validate_primary_key_sources(dsl_state, payload_attribute) do
      {:ok, dsl_state}
    end
  end

  # The resend-tracking opt-in (default :off): declaring :on injects the
  # machine columns resend/2 and replay/2 write — an EXISTING schema is
  # never silently widened; the consumer migrates the four columns.
  defp add_resend_attributes(dsl_state) do
    case Extension.get_opt(dsl_state, [:outbound_delivery], :resend_tracking, :off) do
      :off ->
        {:ok, dsl_state}

      :on ->
        Enum.reduce_while(resend_attributes_spec(), {:ok, dsl_state}, fn {name, type, opts},
                                                                         {:ok, dsl_state} ->
          {:cont, Builder.add_new_attribute(dsl_state, name, type, opts)}
        end)
    end
  end

  defp resend_attributes_spec do
    [
      # unconstrained: the atomic resend bump composes on every supported
      # data layer (a min constraint's expr-error guard is sqlite-atomic-
      # incompatible); the runtime is the only writer
      {:resend_baseline, :integer, [allow_nil?: false, default: 0]},
      {:resend_count, :integer, [allow_nil?: false, default: 0]},
      {:last_resend_by, :string, [constraints: [max_length: 255]]},
      {:last_resend_at, :utc_datetime_usec, []}
    ]
  end

  # The test-flag opt-in (default :off): `test` marks test_send rows
  defp add_test_attributes(dsl_state) do
    case Extension.get_opt(dsl_state, [:outbound_delivery], :test_tracking, :off) do
      :off ->
        {:ok, dsl_state}

      :on ->
        Builder.add_new_attribute(dsl_state, :test, :boolean,
          allow_nil?: false,
          default: false,
          public?: true
        )
    end
  end

  # The configured name replaces :payload in the injected spec; every
  # other spec name is reserved against it (the scope_identity pattern).
  defp check_payload_attribute(dsl_state) do
    resource = Transformer.get_persisted(dsl_state, :resource)

    payload_attribute =
      Extension.get_opt(dsl_state, [:outbound_delivery], :payload_attribute, :payload)

    reserved =
      (Enum.map(attributes_spec(payload_attribute), &elem(&1, 0)) -- [payload_attribute]) ++
        Enum.map(resend_attributes_spec(), &elem(&1, 0)) ++ [:test]

    if payload_attribute in [:id | reserved] do
      {:error,
       DslError.exception(
         module: resource,
         path: [:outbound_delivery, :payload_attribute],
         message:
           "payload_attribute #{inspect(payload_attribute)} collides with an injected ledger field; the exact-bytes column cannot replace an identity or machine field"
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

  defp validate_primary_key_sources(dsl_state, payload_attribute) do
    resource = Transformer.get_persisted(dsl_state, :resource)

    primary_key =
      dsl_state
      |> Transformer.get_entities([:attributes])
      |> Enum.filter(& &1.primary_key?)

    primary_key_names = Enum.map(primary_key, & &1.name)

    supplied =
      MapSet.new([
        :event_uuid,
        :event_type,
        payload_attribute,
        :endpoint_id,
        :subscription_id,
        :signing_mode,
        :dispatch_source,
        :dispatch_route
      ])

    unobtainable =
      primary_key
      |> Enum.reject(fn attribute ->
        attribute.generated? or not is_nil(attribute.default) or
          (attribute.writable? and MapSet.member?(supplied, attribute.name)) or
          (primary_key_names == [:id] and attribute.writable?)
      end)

    case unobtainable do
      [] ->
        :ok

      attributes ->
        names = Enum.map(attributes, & &1.name)

        {:error,
         DslError.exception(
           module: resource,
           path: [:outbound_delivery],
           message:
             "primary key components #{inspect(names)} are unobtainable during dispatch; " <>
               "give each component a default/data-layer generator or use a writable field supplied by the :dispatch action"
         )}
    end
  end

  defp attributes_spec(payload_attribute) do
    [
      {:event_uuid, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {:event_type, :string, [allow_nil?: false, constraints: [max_length: 255]]},
      {payload_attribute, :binary, [allow_nil?: false]},
      {:endpoint_id, :uuid, [allow_nil?: false]},
      {:subscription_id, :uuid, []},
      {:signing_mode, :atom, [constraints: [one_of: [:legacy, :dual, :standard]]]},
      {:dispatch_source, :string,
       [allow_nil?: false, default: "v1:direct:unbound", constraints: [max_length: 1024]]},
      {:dispatch_route, :string,
       [allow_nil?: false, default: "v1:route:unbound", constraints: [max_length: 1024]]},
      {:status, :atom,
       [
         allow_nil?: false,
         default: :pending,
         constraints: [one_of: AshHooks.OutboundDelivery.statuses()]
       ]},
      {:attempts, :integer, [allow_nil?: false, default: 0]},
      {:attempt_token, :uuid, [writable?: false]},
      {:send_lease_expires_at, :utc_datetime_usec, [writable?: false]},
      {:enqueue_token, :uuid, [writable?: false]},
      {:enqueue_lease_expires_at, :utc_datetime_usec, [writable?: false]},
      {:endpoint_snapshot, :map, [writable?: false]},
      {:response_status, :integer, [writable?: false]},
      {:response_snippet, :string, [writable?: false, constraints: [max_length: 2048]]},
      {:last_error, :string, [constraints: [max_length: 255]]},
      {:next_attempt_at, :utc_datetime_usec, [writable?: false]}
    ]
  end
end
