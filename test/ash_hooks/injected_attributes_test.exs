Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.InjectedAttributeStates do
  @moduledoc false
  alias Spark.Dsl.Transformer

  def state(extension, section) do
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
    |> Transformer.set_option([section], :providers, default: AshHooks.TestProvider)
    |> Transformer.set_option([section, :auto_disable], :failure_share, 0.5)
  end
end

defmodule AshHooks.InjectedAttributesTest.Term do
  use Ash.Type.NewType, subtype_of: :term
end

defmodule AshHooks.InjectedAttributesTest do
  use ExUnit.Case, async: false
  require Spark.Test

  alias Ash.Resource.{Builder, Info}
  alias AshHooks.InjectedAttributeStates
  alias AshHooks.Subscription
  alias Spark.Error.DslError
  alias AshHooks.Verifiers.InjectedAttributes
  alias Spark.Dsl.Transformer

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

  for {extension, section, transformer} <- @families do
    @extension extension
    @section section
    @transformer transformer

    test "#{section} checks every selected native attribute and accepts identical declarations" do
      state = InjectedAttributeStates.state(@extension, @section)
      specs = @transformer.attributes_spec(state)

      state =
        Enum.reduce(specs, state, fn {name, type, opts}, state ->
          {:ok, attribute} = Builder.build_attribute(name, type, opts)
          Transformer.add_entity(state, [:attributes], attribute)
        end)

      assert :ok = InjectedAttributes.verify(state)
      assert InjectedAttributes in @extension.verifiers()
    end

    for {name, _type, _opts} <-
          transformer.attributes_spec(InjectedAttributeStates.state(extension, section)) do
      @attribute name

      if name not in [:endpoint_id, :subscription_id] do
        test "#{section}.#{name} refuses an incompatible host type that cannot store package input" do
          {state, actual, type, opts} =
            attribute_state(@extension, @section, @transformer, @attribute)

          value = example(type, opts)
          wrong = if is_map(value), do: Ash.Type.Boolean, else: Ash.Type.Map
          assert {:ok, _} = Ash.Type.cast_input(actual.type, value, actual.constraints)
          refute match?({:ok, _}, Ash.Type.cast_input(wrong, value, []))
          invalid = replace(state, %{actual | type: wrong, constraints: []})

          assert_raise DslError, ~r/attribute .* declares .*accepted shapes/s, fn ->
            InjectedAttributes.verify(invalid)
          end
        end
      end

      test "#{section}.#{name} checks host nullability against package input and matching needs" do
        {state, actual, _type, _opts} =
          attribute_state(@extension, @section, @transformer, @attribute)

        invalid = replace(state, %{actual | allow_nil?: not actual.allow_nil?})

        either? =
          (@section == :subscription and
             @attribute in [:event_types, :event_filters, :signing_mode]) or
            (@section == :endpoint and
               @attribute in [:status, :response_capture, :response_capture_retention_seconds])

        if either? do
          assert :ok = InjectedAttributes.verify(invalid)
        else
          assert_raise DslError, ~r/allow_nil\?/, fn ->
            InjectedAttributes.verify(invalid)
          end
        end
      end
    end
  end

  test "a host string URL retains the working outbound options contract" do
    {state, actual, _type, _opts} =
      attribute_state(
        AshHooks.Endpoint,
        :endpoint,
        AshHooks.Endpoint.Transformers.AddEndpointFields,
        :url
      )

    assert :ok = InjectedAttributes.verify(replace(state, %{actual | type: Ash.Type.String}))
    assert {:ok, "https://example.com/events"} =
             Ash.Type.cast_input(:string, "https://example.com/events", [])
  end

  test "nullable endpoint status keeps the package disabled semantics" do
    endpoint = struct(AshHooks.OutboxFixtures.SQLite.Endpoint, status: nil)
    refute AshHooks.Endpoint.enabled?(endpoint)
    assert AshHooks.Endpoint.enabled?(%{endpoint | status: :enabled})
  end

  test "nil pause breaks the final guard while nil event types match nothing" do
    assert_raise ArgumentError, fn -> not Map.fetch!(%{paused: nil}, :paused) end

    refute Subscription.matches?(%{event_types: nil}, "changed")

    for {name, type} <- [{:paused, :boolean}] do
      errors =
        Spark.Test.dsl_errors do
          subscription(
            quote do
              attribute unquote(name), unquote(type), allow_nil?: true
            end
          )
        end

      assert [{_, [error]}] = errors
      assert Exception.message(error) =~ ~r/allow_nil\?: true.*required/s
    end
  end

  test "host declarations matching the native subscription types compile" do
    resource =
      subscription(
        quote do
          attribute :paused, :boolean, allow_nil?: false, default: false
          attribute :event_types, {:array, :string}, allow_nil?: true, default: ["*"]
          attribute :signing_mode, :atom, allow_nil?: false, default: :standard
          attribute :event_filters, :map, allow_nil?: false, default: %{}
        end
      )

    refute Info.attribute(resource, :event_filters).allow_nil?
    assert Subscription.matches_filters?(struct(resource, event_filters: %{}), %{})
  end

  for type <- [
        {:array, :integer},
        {:array, :boolean},
        {:array, :map},
        :map,
        :boolean,
        :integer,
        :string
      ] do
    @event_type type
    test "#{inspect(type)} event types cannot carry a declared event name" do
      type = @event_type
      {:ok, attribute} = Builder.build_attribute(:event_types, type, [])

      refute match?(
               {:ok, _},
               Ash.Type.cast_input(attribute.type, ["changed"], attribute.constraints)
             )

      errors =
        Spark.Test.dsl_errors do
          subscription(
            quote do
              attribute :event_types, unquote(Macro.escape(type)), allow_nil?: false
            end
          )
        end

      assert [{_, [error]}] = errors
      assert Exception.message(error) =~ "accepted shapes"
    end
  end

  for element <- [Ash.Type.Term, AshHooks.InjectedAttributesTest.Term] do
    @element element
    test "SQLite refuses event arrays using #{inspect(element)} before persistence" do
      element = @element

      errors =
        Spark.Test.dsl_errors do
          subscription(
            quote do
              attribute :event_types, {:array, unquote(element)}, allow_nil?: true
            end,
            AshSqlite.DataLayer
          )
        end

      assert [{_, [error]}] = errors
      assert Exception.message(error) =~ ":erlang.term_to_binary"
      assert Exception.message(error) =~ "ecto_sqlite3's JSON array encoding"
      assert Exception.message(error) =~ "{:array, :string} or {:array, :atom}"
    end
  end

  test "a scalar term admits a non-container that raises in event matching" do
    assert {:ok, "changed"} = Ash.Type.cast_input(:term, "changed", [])
    assert_raise Protocol.UndefinedError, fn ->
      Subscription.matches?(%{event_types: "changed"}, "changed")
    end

    errors =
      Spark.Test.dsl_errors do
        subscription(quote do: attribute(:event_types, :term, allow_nil?: true))
      end

    assert [{_, [error]}] = errors
    assert Exception.message(error) =~ "accepted shapes"
  end

  test "source identity constraints and lossless outbox metadata remain native" do
    source = InjectedAttributeStates.state(AshHooks.InboundSource, :inbound_source)
    specs = AshHooks.InboundSource.Transformers.AddSourceFields.attributes_spec(source)

    source =
      Enum.reduce(specs, source, fn {name, type, opts}, state ->
        {:ok, attribute} = Builder.build_attribute(name, type, opts)
        Transformer.add_entity(state, [:attributes], attribute)
      end)

    provider = Enum.find(Transformer.get_entities(source, [:attributes]), &(&1.name == :provider))

    assert_raise DslError, ~r/constraints/, fn ->
      InjectedAttributes.verify(replace(source, %{provider | constraints: [one_of: [:other]]}))
    end
  end

  defp attribute_state(extension, section, transformer, name) do
    state = InjectedAttributeStates.state(extension, section)
    specs = transformer.attributes_spec(state)

    state =
      Enum.reduce(specs, state, fn {field, type, opts}, state ->
        {:ok, attribute} = Builder.build_attribute(field, type, opts)
        Transformer.add_entity(state, [:attributes], attribute)
      end)

    {^name, type, opts} = Enum.find(specs, &(elem(&1, 0) == name))
    actual = Enum.find(Transformer.get_entities(state, [:attributes]), &(&1.name == name))
    {state, actual, type, opts}
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

  defp example(:atom, opts),
    do: opts |> Keyword.get(:constraints, []) |> Keyword.get(:one_of, [:default]) |> hd()

  defp example(AshHooks.Endpoint.Url, _opts), do: "https://example.com/events"
  defp example(AshHooks.InboundDelivery.Payload, _opts), do: %{"event" => "changed"}
  defp example(_string, _opts), do: "reference"

  defp subscription(attributes, layer \\ Ash.DataLayer.Ets) do
    configuration =
      if layer == AshSqlite.DataLayer do
        quote do
          sqlite do
            table "injected_term_subscriptions"
            repo(AshHooks.OutboxFixtures.SQLiteRepo)
          end
        end
      end

    module = Module.concat(__MODULE__, "Subscription#{System.unique_integer([:positive])}")

    on_exit(fn ->
      :code.purge(module)
      :code.delete(module)
    end)

    Module.create(
      module,
      quote do
        use Ash.Resource,
          data_layer: unquote(layer),
          extensions: [AshHooks.Subscription],
          validate_domain_inclusion?: false

        unquote(configuration)

        attributes do
          unquote(attributes)
        end

        subscription do
          endpoint_resource AshHooks.OutboxFixtures.SQLite.Endpoint
          pausable :on
          filter_attributes [:region]
        end
      end,
      Macro.Env.location(__ENV__)
    )

    module
  end
end
