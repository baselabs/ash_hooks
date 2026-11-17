Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.InjectedAttributesTest do
  use ExUnit.Case, async: false
  require Spark.Test

  alias Ash.Resource.Builder
  alias AshHooks.Verifiers.InjectedAttributes
  alias Spark.Dsl.Transformer

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

  for {extension, section, transformer} <- @families do
    @extension extension
    @section section
    @transformer transformer

    test "#{section} checks every selected native attribute and accepts identical declarations" do
      state = state(@extension, @section)
      specs = @transformer.attributes_spec(state)

      state =
        Enum.reduce(specs, state, fn {name, type, opts}, state ->
          {:ok, attribute} = Builder.build_attribute(name, type, opts)
          Transformer.add_entity(state, [:attributes], attribute)
        end)

      assert :ok = InjectedAttributes.verify(state)
      assert InjectedAttributes in @extension.verifiers()

      for {name, type, opts} <- specs do
        actual = Enum.find(Transformer.get_entities(state, [:attributes]), &(&1.name == name))
        value = example(type, opts)
        wrong = if is_map(value), do: Ash.Type.Boolean, else: Ash.Type.Map
        # The package's action input cannot cast into this host replacement.
        assert {:ok, _} = Ash.Type.cast_input(actual.type, value, actual.constraints)
        refute match?({:ok, _}, Ash.Type.cast_input(wrong, value, []))
        invalid = replace(state, %{actual | type: wrong, constraints: []})
        assert_raise Spark.Error.DslError, ~r/attribute .* declares .*accepted shapes/s, fn ->
          InjectedAttributes.verify(invalid)
        end

        invalid = replace(state, %{actual | allow_nil?: not actual.allow_nil?})

        if @section == :subscription and name == :event_filters do
          assert :ok = InjectedAttributes.verify(invalid)
        else
          assert_raise Spark.Error.DslError, ~r/allow_nil\?/, fn ->
            InjectedAttributes.verify(invalid)
          end
        end
      end
    end
  end

  test "nil pause and nil event types break the real final matching guards" do
    assert_raise ArgumentError, fn -> not Map.fetch!(%{paused: nil}, :paused) end

    assert_raise Protocol.UndefinedError, fn ->
      AshHooks.Subscription.matches?(%{event_types: nil}, "changed")
    end

    for {name, type} <- [{:paused, :boolean}, {:event_types, {:array, :string}}] do
      Spark.Test.assert_dsl_error ~r/allow_nil\?: true.*required/s do
        subscription(quote do
          attribute unquote(name), unquote(type), allow_nil?: true
        end)
      end
    end
  end

  test "host declarations matching the native subscription types compile" do
    resource = subscription(quote do
      attribute :paused, :boolean, allow_nil?: false, default: false
      attribute :event_types, {:array, :string}, allow_nil?: false, default: ["*"]
      attribute :event_filters, :map, allow_nil?: false, default: %{}
    end)

    refute Ash.Resource.Info.attribute(resource, :event_filters).allow_nil?
    assert AshHooks.Subscription.matches_filters?(struct(resource, event_filters: %{}), %{})
  end

  test "non-string and non-atom event elements cannot match canonical event names" do
    refute AshHooks.Subscription.matches?(%{event_types: [1, true, %{}]}, "changed")

    for type <- [:integer, :boolean, :map] do
      Spark.Test.assert_dsl_error ~r/accepted shapes/ do
        subscription(quote do
          attribute :event_types, {:array, unquote(type)}, allow_nil?: false
        end)
      end
    end
  end

  test "source identity constraints and lossless outbox metadata remain native" do
    source = state(AshHooks.InboundSource, :inbound_source)
    specs = AshHooks.InboundSource.Transformers.AddSourceFields.attributes_spec(source)
    source = Enum.reduce(specs, source, fn {name, type, opts}, state ->
      {:ok, attribute} = Builder.build_attribute(name, type, opts)
      Transformer.add_entity(state, [:attributes], attribute)
    end)
    provider = Enum.find(Transformer.get_entities(source, [:attributes]), &(&1.name == :provider))
    assert_raise Spark.Error.DslError, ~r/constraints/, fn ->
      InjectedAttributes.verify(replace(source, %{provider | constraints: [one_of: [:other]]}))
    end
  end

  defp state(extension, section) do
    %{}
    |> Transformer.persist(:module, __MODULE__)
    |> Transformer.persist(:extensions, [extension])
    |> Transformer.set_option([section], :pausable, :on)
    |> Transformer.set_option([section], :filter_attributes, [:region])
    |> Transformer.set_option([section], :record_signing_provenance, :on)
    |> Transformer.set_option([section], :record_verified_facts, :on)
    |> Transformer.set_option([section], :record_provider_alias, :on)
    |> Transformer.set_option([section], :ingress_tracking, :on)
    |> Transformer.set_option([section], :resend_tracking, :on)
    |> Transformer.set_option([section], :test_tracking, :on)
    |> Transformer.set_option([section], :response_capture_attributes, :on)
    |> Transformer.set_option([section], :key_lifecycle, :on)
    |> Transformer.set_option([section], :legacy_key_lifecycle, :on)
    |> Transformer.set_option([section], :custodian, AshHooks.Test.Custodian)
    |> Transformer.set_option([section], :version_pinning, :on)
    |> Transformer.set_option([section], :scope, [{:region, :string, []}])
    |> Transformer.set_option([section], :providers, [default: AshHooks.TestProvider])
    |> Transformer.set_option([section, :auto_disable], :failure_share, 0.5)
  end

  defp replace(state, attribute),
    do: Transformer.replace_entity(state, [:attributes], attribute, &(&1.name == attribute.name))

  defp example({:array, type}, opts), do: [example(type, Keyword.get(opts, :constraints, []))]
  defp example(:boolean, _opts), do: true
  defp example(:integer, _opts), do: 1
  defp example(:uuid, _opts), do: Ash.UUID.generate()
  defp example(:utc_datetime_usec, _opts), do: DateTime.utc_now()
  defp example(:map, _opts), do: %{"region" => "west"}
  defp example(:term, _opts), do: {:key_kind, :standard}
  defp example(:atom, opts), do: opts |> Keyword.get(:constraints, []) |> Keyword.get(:one_of, [:default]) |> hd()
  defp example(AshHooks.Endpoint.Url, _opts), do: "https://example.com/events"
  defp example(AshHooks.InboundDelivery.Payload, _opts), do: %{"event" => "changed"}
  defp example(_string, _opts), do: "reference"

  defp subscription(attributes) do
    module = Module.concat(__MODULE__, "Subscription#{System.unique_integer([:positive])}")
    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    Module.create(module, quote do
      use Ash.Resource,
        data_layer: Ash.DataLayer.Ets,
        extensions: [AshHooks.Subscription],
        validate_domain_inclusion?: false

      attributes do
        unquote(attributes)
      end

      subscription do
        endpoint_resource AshHooks.OutboxFixtures.SQLite.Endpoint
        pausable :on
        filter_attributes [:region]
      end
    end, Macro.Env.location(__ENV__))
    module
  end
end
