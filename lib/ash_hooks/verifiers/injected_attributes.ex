defmodule AshHooks.Verifiers.InjectedAttributes do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Builder
  alias Ash.Type.NewType
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @families [
    {AshHooks.Subscription, :subscription,
     AshHooks.Subscription.Transformers.AddSubscriptionFields},
    {AshHooks.Endpoint, :endpoint, AshHooks.Endpoint.Transformers.AddEndpointFields},
    {AshHooks.OutboundDelivery, :outbound_delivery,
     AshHooks.OutboundDelivery.Transformers.AddDeliveryFields},
    {AshHooks.OutboundAttempt, :outbound_attempt,
     AshHooks.OutboundAttempt.Transformers.AddAttemptFields},
    {AshHooks.OutboundEvent, :outbound_event, AshHooks.OutboundEvent.Transformers.AddEventFields},
    {AshHooks.InboundDelivery, :inbound_delivery,
     AshHooks.InboundDelivery.Transformers.AddLedgerFields},
    {AshHooks.InboundSource, :inbound_source,
     AshHooks.InboundSource.Transformers.AddSourceFields},
    {AshHooks.KeyRegistry, :key_registry, AshHooks.KeyRegistry.Transformers.AddRegistry},
    {AshHooks.OutboundOutbox, :outbox, AshHooks.OutboundOutbox.Transformers.AddOutbox}
  ]

  def verify(state) do
    for {extension, section, transformer} <- @families,
        extension in Spark.extensions(state) do
      verify_attributes!(state, section, transformer.attributes_spec(state))
    end

    :ok
  end

  def verify_attributes!(state, section, specs) do
    for {name, type, opts} <- specs do
      {:ok, expected} = Builder.build_attribute(name, type, opts)
      actual = Enum.find(Verifier.get_entities(state, [:attributes]), &(&1.name == name))
      verify_attribute!(state, section, actual, expected)
    end

    :ok
  end

  defp verify_attribute!(state, section, actual, expected) do
    nullable = nullability(section, expected)

    unless accepted_type?(section, actual, expected) and
             (nullable == :either or actual.allow_nil? == (nullable == :nullable)) and
             accepted_constraints?(section, actual, expected) do
      raise DslError,
        module: Verifier.get_persisted(state, :module),
        path: [section, :attributes, actual.name],
        message:
          "attribute #{inspect(actual.name)} declares #{inspect(actual.type)}, " <>
            "allow_nil?: #{inspect(actual.allow_nil?)}, constraints: #{inspect(actual.constraints)}; " <>
            "must match accepted shapes: #{accepted_types(section, expected)}; #{inspect(nullable)} nullability"
    end

    verify_storage!(state, section, actual)
  end

  defp verify_storage!(state, :subscription, %{name: :event_types} = attribute) do
    if Verifier.get_persisted(state, :data_layer) == AshSqlite.DataLayer and
         type_matches?(attribute.type, {:array, Ash.Type.Term}) do
      raise DslError,
        module: Verifier.get_persisted(state, :module),
        path: [:subscription, :attributes, :event_types],
        message:
          "attribute :event_types declares #{inspect(attribute.type)}, " <>
            "allow_nil?: #{inspect(attribute.allow_nil?)}; Term storage uses " <>
            ":erlang.term_to_binary, which ecto_sqlite3's JSON array encoding cannot carry. " <>
            "Use {:array, :string} or {:array, :atom}, including element NewTypes, on AshSqlite.DataLayer."
    end
  end

  defp verify_storage!(_state, _section, _attribute), do: :ok

  # The consumer owns filters. Both nil and a map have defined matching semantics.
  defp nullability(:subscription, %{name: name})
       when name in [:event_types, :event_filters, :signing_mode],
       do: :either

  defp nullability(:endpoint, %{name: name})
       when name in [:status, :response_capture, :response_capture_retention_seconds],
       do: :either

  defp nullability(_section, %{allow_nil?: false}), do: :required
  # Other nullable fields are cleared or supplied as nil by package actions.
  defp nullability(_section, _expected), do: :nullable

  defp accepted_type?(section, actual, expected) do
    native = Ash.Type.get_type(expected.type)

    cond do
      # OutboundReferences owns reference storage validation against the joined key.
      expected.name in [:endpoint_id, :subscription_id] ->
        true

      section == :subscription and expected.name == :event_types ->
        type_matches?(actual.type, {:array, Ash.Type.String}) or
          type_matches?(actual.type, {:array, Ash.Type.Atom}) or
          type_matches?(actual.type, {:array, Ash.Type.Term})

      native in [AshHooks.Endpoint.SecretRef, AshHooks.Endpoint.Url] ->
        type_matches?(actual.type, native) or type_matches?(actual.type, Ash.Type.String)

      true ->
        type_matches?(actual.type, native)
    end
  end

  defp type_matches?({:array, actual}, {:array, native}), do: type_matches?(actual, native)

  defp type_matches?(actual, native) do
    actual == native or
      (NewType.new_type?(actual) and type_matches?(actual.subtype_of(), native))
  end

  defp accepted_constraints?(:outbox, %{name: :metadata} = actual, _expected),
    do: actual.type == Ash.Type.Map and not Keyword.has_key?(actual.constraints, :fields)

  # Scope identity and provider aliases must keep the declared value domain.
  defp accepted_constraints?(:inbound_source, actual, %{allow_nil?: false} = expected) do
    {:ok, expected_constraints} = Ash.Type.init(expected.type, expected.constraints)
    {:ok, actual_constraints} = Ash.Type.init(actual.type, actual.constraints)
    expected_constraints == actual_constraints
  end

  defp accepted_constraints?(_section, _actual, _expected), do: true

  defp accepted_types(:outbox, %{name: :metadata}),
    do: "unmodified :map without a :fields constraint"

  defp accepted_types(:subscription, %{name: :event_types}),
    do: "{:array, :string}, {:array, :atom} or {:array, :term}, including native NewType subtypes"

  defp accepted_types(_section, %{type: AshHooks.Endpoint.Url}),
    do: "AshHooks.Endpoint.Url or :string, including native NewType subtypes"

  defp accepted_types(_section, %{type: AshHooks.Endpoint.SecretRef}),
    do: "AshHooks.Endpoint.SecretRef or :string, including native NewType subtypes"

  defp accepted_types(_section, %{name: name}) when name in [:endpoint_id, :subscription_id],
    do: "a UUID-storage-compatible reference"

  defp accepted_types(_section, expected),
    do: "#{inspect(expected.type)}, including native NewType subtypes"
end
