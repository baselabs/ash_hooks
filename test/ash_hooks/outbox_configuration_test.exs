Code.require_file("outbox_process.exs", __DIR__)
Code.require_file("outbox_resources.exs", __DIR__)

defmodule AshHooks.OutboxConfigurationTest do
  use ExUnit.Case, async: false
  alias Ash.Resource.Info
  alias AshHooks.OutboundOutbox.Transformers.AddOutbox
  alias AshHooks.OutboundOutbox.Verifier
  alias AshHooks.OutboxFixtures.Postgres.Outbox, as: PostgresOutbox
  alias Spark.Dsl.Transformer
  @resource AshHooks.OutboxFixtures.SQLite.Outbox

  test "A17 generated attributes and actions precede Ash input and identity caches" do
    for transformer <- [
          Ash.Resource.Transformers.DefaultAccept,
          Ash.Resource.Transformers.CacheActionInputs,
          Ash.Resource.Transformers.SetPrimaryActions,
          Ash.Resource.Transformers.RequireUniqueActionNames,
          Ash.Resource.Transformers.CachePrimaryKey,
          Ash.Resource.Transformers.AttributesByName,
          Ash.Resource.Transformers.SetPreCheckWith,
          Ash.Resource.Transformers.CacheUniqueKeys,
          Ash.Resource.Transformers.SetEagerCheckWith
        ] do
      assert AddOutbox.before?(transformer)
    end

    refute AddOutbox.before?(__MODULE__)
    assert :event_uuid in Info.action_inputs(@resource, :publish)
    assert "acceptance_token" in Info.action_inputs(@resource, :publish)
    assert %{name: :claim_token} = Info.attribute(@resource, :claim_token)

    assert Enum.any?(Info.unique_keys(@resource), fn key ->
             Enum.sort(key.keys) == [:event_uuid, :org_id]
           end)
  end

  test "A17 migration configuration includes tenant-leading recovery indexes" do
    for {resource, path} <- [
          {@resource, [:sqlite, :custom_indexes]},
          {PostgresOutbox, [:postgres, :custom_indexes]}
        ] do
      {:ok, transformed} = AddOutbox.transform(resource.spark_dsl_config())

      indexes = Transformer.get_entities(transformed, path)
      assert length(indexes) == 2

      assert Enum.any?(
               indexes,
               &(&1.fields == [:org_id, :next_attempt_at] and &1.where == "\"state\" = 'pending'")
             )

      assert Enum.any?(
               indexes,
               &(&1.fields == [:org_id, :failed_at] and &1.where == "\"state\" = 'failed'")
             )
    end
  end

  test "A6 tenant identity cannot be widened, narrowed or made partial" do
    state = @resource.spark_dsl_config()

    identity =
      Enum.find(Transformer.get_entities(state, [:identities]), &(&1.name == :unique_publication))

    for changes <- [[all_tenants?: true], [keys: [:event_uuid]], [where: [state: :pending]]] do
      changed = struct(identity, changes)

      invalid =
        Transformer.replace_entity(
          state,
          [:identities],
          changed,
          &(&1.name == :unique_publication)
        )

      assert {:error, %Spark.Error.DslError{message: message}} = Verifier.verify(invalid)
      assert message =~ "unique_publication"
    end
  end

  test "A9 metadata refuses constrained fields and custom codecs" do
    state = @resource.spark_dsl_config()
    metadata = Enum.find(Transformer.get_entities(state, [:attributes]), &(&1.name == :metadata))

    for changes <- [[type: Ash.Type.String], [constraints: [fields: []]]] do
      invalid =
        Transformer.replace_entity(
          state,
          [:attributes],
          struct(metadata, changes),
          &(&1.name == :metadata)
        )

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
