Code.require_file("outbox_process.exs", __DIR__)
Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.OutboxConfigurationTest do
  use ExUnit.Case, async: false
  alias AshHooks.OutboundOutbox.Verifier
  alias Spark.Dsl.Transformer
  @resource AshHooks.OutboxFixtures.SQLite.Outbox

  test "A6 tenant identity cannot be widened, narrowed or made partial" do
    state = @resource.spark_dsl_config()

    identity =
      Enum.find(Transformer.get_entities(state, [:identities]), &(&1.name == :unique_publication))

    for changes <- [[all_tenants?: true], [keys: [:event_uuid]], [where: [state: :pending]]] do
      changed = struct(identity, changes)
      invalid = Transformer.replace_entity(state, [:identities], changed, &(&1.name == :unique_publication))
      assert {:error, %Spark.Error.DslError{message: message}} = Verifier.verify(invalid)
      assert message =~ "unique_publication"
    end
  end

  test "A9 metadata refuses constrained fields and custom codecs" do
    state = @resource.spark_dsl_config()
    metadata = Enum.find(Transformer.get_entities(state, [:attributes]), &(&1.name == :metadata))

    for changes <- [[type: Ash.Type.String], [constraints: [fields: []]]] do
      invalid = Transformer.replace_entity(state, [:attributes], struct(metadata, changes), &(&1.name == :metadata))
      assert {:error, %Spark.Error.DslError{message: message}} = Verifier.verify(invalid)
      assert message =~ "unmodified :map"
    end

    invalid =
      state
      |> Transformer.persist(:data_layer, AshPostgres.DataLayer)
      |> Transformer.set_option([:postgres], :storage_types, metadata: :binary)

    assert {:error, %Spark.Error.DslError{message: message}} = Verifier.verify(invalid)
    assert message =~ "codec"

    invalid =
      state
      |> Transformer.persist(:data_layer, AshPostgres.DataLayer)
      |> Transformer.set_option([:postgres], :migration_types, metadata: :jsonb)

    assert {:error, %Spark.Error.DslError{message: message}} = Verifier.verify(invalid)
    assert message =~ "native :json"
  end

  test "A5 deadlines and retry budgets reject unsafe configurations" do
    state = @resource.spark_dsl_config()

    for {key, value, text} <- [
          {:fanout_timeout, 2_000, "below"},
          {:fanout_base_backoff_seconds, 3, "must not exceed"}
        ] do
      invalid = Transformer.set_option(state, [:outbox], key, value)
      assert {:error, %Spark.Error.DslError{message: message}} = Verifier.verify(invalid)
      assert message =~ text
    end
  end

  test "A10 routes are closed, named and exported with the required arity" do
    state = @resource.spark_dsl_config()

    for routes <- [[], [default: nil, default: nil]] do
      assert {:error, %Spark.Error.DslError{message: message}} =
               Verifier.verify(Transformer.set_option(state, [:outbox], :delivery_routes, routes))

      assert message =~ "distinct"
    end

    for callback <- [:invalid, {String, :not_exported}, {String, :length}] do
      assert_raise Spark.Error.DslError, ~r/two-argument/, fn ->
        Verifier.verify(
          Transformer.set_option(state, [:outbox], :delivery_routes, default: callback)
        )
      end
    end

    assert_raise Spark.Error.DslError, ~r/trigger must/, fn ->
      Verifier.verify(Transformer.set_option(state, [:outbox], :trigger, {String, :not_exported}))
    end

    assert :ok = Verifier.verify(Transformer.set_option(state, [:outbox], :trigger, nil))
  end

  test "A13 default retries span the recovery day and stay below delivery reconciliation" do
    defaults = AshHooks.OutboundOutbox.sections() |> hd() |> Map.fetch!(:schema)
    option = fn name -> defaults |> Keyword.fetch!(name) |> Keyword.fetch!(:default) end
    cap = option.(:fanout_max_attempts)
    base = option.(:fanout_base_backoff_seconds)
    ceiling = option.(:fanout_max_backoff_seconds)
    assert ceiling < 300

    assert Enum.sum(
             for attempt <- 1..(cap - 1),
                 do: min(ceiling, base * Integer.pow(2, min(attempt - 1, 30)))
           ) >= 86_400
  end
end
