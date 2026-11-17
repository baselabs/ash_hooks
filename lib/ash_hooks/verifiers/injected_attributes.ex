defmodule AshHooks.Verifiers.InjectedAttributes do
  @moduledoc false
  use Spark.Dsl.Verifier

  alias Ash.Resource.Builder
  alias Spark.Dsl.Verifier
  alias Spark.Error.DslError

  @families [
    {AshHooks.Subscription, :subscription, AshHooks.Subscription.Transformers.AddSubscriptionFields},
    {AshHooks.Endpoint, :endpoint, AshHooks.Endpoint.Transformers.AddEndpointFields},
    {AshHooks.OutboundDelivery, :outbound_delivery, AshHooks.OutboundDelivery.Transformers.AddDeliveryFields},
    {AshHooks.OutboundAttempt, :outbound_attempt, AshHooks.OutboundAttempt.Transformers.AddAttemptFields},
    {AshHooks.OutboundEvent, :outbound_event, AshHooks.OutboundEvent.Transformers.AddEventFields},
    {AshHooks.InboundDelivery, :inbound_delivery, AshHooks.InboundDelivery.Transformers.AddLedgerFields},
    {AshHooks.InboundSource, :inbound_source, AshHooks.InboundSource.Transformers.AddSourceFields},
    {AshHooks.KeyRegistry, :key_registry, AshHooks.KeyRegistry.Transformers.AddRegistry},
    {AshHooks.OutboundOutbox, :outbox, AshHooks.OutboundOutbox.Transformers.AddOutbox}
  ]

  def verify(state) do
    for {extension, section, transformer} <- @families,
        extension in Spark.extensions(state),
        {name, type, opts} <- transformer.attributes_spec(state) do
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
            "accepted shapes: #{accepted_types(section, expected)}; #{inspect(nullable)} nullability"
    end
  end

  # The consumer owns filters. Both nil and a map have defined matching semantics.
  defp nullability(:subscription, %{name: :event_filters}), do: :either
  defp nullability(_section, %{allow_nil?: false}), do: :required
  # Other nullable fields are cleared or supplied as nil by package actions.
  defp nullability(_section, _expected), do: :nullable

  defp accepted_type?(section, actual, expected) do
    type = Ash.Type.NewType.subtype_of(actual.type)
    native = Ash.Type.get_type(expected.type)

    cond do
      expected.name in [:endpoint_id, :subscription_id] ->
        Ash.Type.storage_type(actual.type, actual.constraints) == :uuid

      section == :subscription and expected.name == :event_types ->
        type in [{:array, Ash.Type.String}, {:array, Ash.Type.Atom}]

      native == AshHooks.Endpoint.SecretRef ->
        type in [native, Ash.Type.String]

      true ->
        type == native
    end
  end

  defp accepted_constraints?(:outbox, %{name: :metadata} = actual, _expected),
    do: actual.type == Ash.Type.Map and not Keyword.has_key?(actual.constraints, :fields)

  # Scope identity and provider aliases must keep the declared value domain.
  defp accepted_constraints?(:inbound_source, actual, expected) do
    {:ok, expected_constraints} = Ash.Type.init(expected.type, expected.constraints)
    {:ok, actual_constraints} = Ash.Type.init(actual.type, actual.constraints)
    expected_constraints == actual_constraints
  end

  defp accepted_constraints?(_section, _actual, _expected), do: true

  defp accepted_types(:outbox, %{name: :metadata}),
    do: "unmodified :map without a :fields constraint"

  defp accepted_types(:subscription, %{name: :event_types}),
    do: "{:array, :string} or {:array, :atom}, including native NewType subtypes"

  defp accepted_types(_section, %{type: AshHooks.Endpoint.SecretRef}),
    do: "AshHooks.Endpoint.SecretRef or :string, including native NewType subtypes"

  defp accepted_types(_section, %{name: name}) when name in [:endpoint_id, :subscription_id],
    do: "a UUID-storage-compatible reference"

  defp accepted_types(_section, expected),
    do: "#{inspect(expected.type)}, including native NewType subtypes"
end
