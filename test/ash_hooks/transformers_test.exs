defmodule AshHooks.TransformersTest do
  @moduledoc """
  The DSL transformers run at RESOURCE compile time — under `mix test`
  that is the test-compile window, before :cover starts, so their sorting
  hooks (before?/1) and the shape-driven branches never light up in the
  ordinary suites. This file compiles REAL resources at RUNTIME (the
  purged-fixture pattern from the E2E suite) to drive them under cover:
  a resource declaring its own primary key (the add-only-if-absent arm)
  and a scope_identity slot colliding with a reserved ledger field (the
  fail-closed DslError).
  """

  use ExUnit.Case, async: false

  @endpoint_resource """
  defmodule AshHooks.TfEndpoint do
    use Ash.Resource,
      domain: AshHooks.TfDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.Endpoint]

    attributes do
      uuid_primary_key(:custom_id)
    end

    actions do
      defaults([:read, :create, :update])
      default_accept(:*)
    end
  end
  """

  @subscription_resource """
  defmodule AshHooks.TfSubscription do
    use Ash.Resource,
      domain: AshHooks.TfDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.Subscription]

    attributes do
      uuid_primary_key(:custom_id)
    end

    actions do
      defaults([:read, :create])
      default_accept(:*)
    end
  end
  """

  @ledger_resource """
  defmodule AshHooks.TfLedger do
    use Ash.Resource,
      domain: AshHooks.TfDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks, AshHooks.InboundDelivery]

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    webhooks do
      inbound(:counter) do
        provider(AshHooks.CountingProvider)
        secret(fn -> {:ok, "tf-secret"} end)
      end
    end
  end
  """

  @delivery_resource """
  defmodule AshHooks.TfDelivery do
    use Ash.Resource,
      domain: AshHooks.TfDomain,
      data_layer: Ash.DataLayer.Ets,
      extensions: [AshHooks.OutboundDelivery]

    actions do
      defaults([:read])
    end
  end
  """

  setup_all do
    Code.compile_string("""
    defmodule AshHooks.TfDomain do
      use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

      resources do
        resource(AshHooks.TfEndpoint)
        resource(AshHooks.TfSubscription)
        resource(AshHooks.TfLedger)
        resource(AshHooks.TfDelivery)
      end
    end
    """)

    on_exit(fn ->
      for mod <- [
            AshHooks.TfEndpoint,
            AshHooks.TfSubscription,
            AshHooks.TfLedger,
            AshHooks.TfDelivery,
            AshHooks.TfDomain
          ] do
        :code.purge(mod)
        :code.delete(mod)
      end
    end)

    :ok
  end

  test "resources declaring their own primary keys compile — reserved attrs add around them" do
    for {source, mod} <- [
          {@endpoint_resource, AshHooks.TfEndpoint},
          {@subscription_resource, AshHooks.TfSubscription},
          {@ledger_resource, AshHooks.TfLedger},
          {@delivery_resource, AshHooks.TfDelivery}
        ] do
      assert Enum.any?(Code.compile_string(source), fn {m, _} -> m == mod end)
    end
  end

  test "every injected transformer declares its ordering before the cache it feeds" do
    pairs = [
      {AshHooks.OutboundDelivery.Transformers.AddDeliveryActions,
       Ash.Resource.Transformers.CacheActionInputs},
      {AshHooks.OutboundDelivery.Transformers.AddSendActions,
       Ash.Resource.Transformers.CacheActionInputs},
      {AshHooks.OutboundDelivery.Transformers.AddDeliveryIdentity,
       Ash.Resource.Transformers.CacheUniqueKeys},
      {AshHooks.InboundDelivery.Transformers.AddFencedActions,
       Ash.Resource.Transformers.CacheActionInputs},
      {AshHooks.InboundDelivery.Transformers.AddLedgerIdentity,
       Ash.Resource.Transformers.CacheUniqueKeys},
      {AshHooks.Endpoint.Transformers.AddEndpointActions,
       Ash.Resource.Transformers.CacheActionInputs},
      {AshHooks.Subscription.Transformers.AddSubscriptionFields,
       Ash.Resource.Transformers.AttributesByName},
      {AshHooks.Endpoint.Transformers.AddEndpointFields,
       Ash.Resource.Transformers.AttributesByName},
      {AshHooks.InboundDelivery.Transformers.AddLedgerFields,
       Ash.Resource.Transformers.AttributesByName},
      {AshHooks.OutboundDelivery.Transformers.AddDeliveryFields,
       Ash.Resource.Transformers.AttributesByName}
    ]

    for {transformer, cached} <- pairs do
      assert transformer.before?(cached),
             "#{inspect(transformer)} must run before #{inspect(cached)} or its injected fields/actions miss the cache"
    end
  end

  test "a scope_identity slot colliding with a reserved ledger field fails closed at compile" do
    source =
      String.replace(
        @ledger_resource,
        "scope_identity([:account_id])",
        "scope_identity([:status])"
      )

    assert_raise Spark.Error.DslError, ~r/collides/, fn ->
      Code.compile_string(source)
    end
  after
    :code.purge(AshHooks.TfLedger)
    :code.delete(AshHooks.TfLedger)
  end
end
