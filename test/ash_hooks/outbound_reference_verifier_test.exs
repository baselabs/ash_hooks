defmodule AshHooks.OutboundReferenceVerifierFixtures do
  defmacro define_resources(suffix, endpoint_kind, subscription_kind, delivery_kind, emitter?) do
    base = Module.concat(AshHooks.OutboundReferenceVerifierTest, suffix)

    modules = %{
      endpoint: Module.concat(base, Endpoint),
      subscription: Module.concat(base, Subscription),
      delivery: Module.concat(base, Delivery),
      emitter: Module.concat(base, Emitter)
    }

    endpoint_attributes = endpoint_attributes(endpoint_kind)
    subscription_attributes = subscription_attributes(subscription_kind)
    delivery_attributes = delivery_attributes(delivery_kind)
    emitter = emitter_definition(modules, emitter?)

    quote do
      defmodule unquote(modules.endpoint) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer,
          validate_domain_inclusion?: false,
          extensions: [AshHooks.Endpoint]

        sqlite do
          table("outbound_reference_verifier_endpoints")
          repo(AshHooks.Test.Repo)
        end

        attributes do
          unquote(endpoint_attributes)
        end

        actions do
          defaults([:read])
        end
      end

      defmodule unquote(modules.subscription) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer,
          validate_domain_inclusion?: false,
          extensions: [AshHooks.Subscription]

        sqlite do
          table("outbound_reference_verifier_subscriptions")
          repo(AshHooks.Test.Repo)
        end

        attributes do
          unquote(subscription_attributes)
        end

        subscription do
          endpoint_resource(unquote(modules.endpoint))
        end

        actions do
          defaults([:read])
        end
      end

      defmodule unquote(modules.delivery) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer,
          validate_domain_inclusion?: false,
          extensions: [AshHooks.OutboundDelivery]

        sqlite do
          table("outbound_reference_verifier_deliveries")
          repo(AshHooks.Test.Repo)
        end

        attributes do
          unquote(delivery_attributes)
        end

        actions do
          defaults([:read])
        end
      end

      unquote(emitter)
    end
  end

  defp endpoint_attributes(:uuid), do: quote(do: uuid_primary_key(:endpoint_key))
  defp endpoint_attributes(:v7), do: quote(do: uuid_v7_primary_key(:endpoint_key))
  defp endpoint_attributes(:integer), do: quote(do: integer_primary_key(:endpoint_number))

  defp endpoint_attributes(:composite) do
    quote do
      attribute(:account_id, :uuid, primary_key?: true, allow_nil?: false)
      attribute(:endpoint_number, :uuid, primary_key?: true, allow_nil?: false)
    end
  end

  defp subscription_attributes(:uuid), do: quote(do: uuid_primary_key(:subscription_key))
  defp subscription_attributes(:integer), do: quote(do: integer_primary_key(:subscription_number))

  defp subscription_attributes(:v7_compatible) do
    quote do
      uuid_v7_primary_key(:subscription_key)
      attribute(:endpoint_id, :uuid_v7, allow_nil?: false)
    end
  end

  defp subscription_attributes(:bad_ref) do
    quote do
      uuid_primary_key(:subscription_key)
      attribute(:endpoint_id, :string, allow_nil?: false)
    end
  end

  defp delivery_attributes(:uuid), do: quote(do: uuid_primary_key(:delivery_key))

  defp delivery_attributes(:v7_compatible) do
    quote do
      uuid_v7_primary_key(:delivery_key)
      attribute(:endpoint_id, :uuid_v7, allow_nil?: false)
      attribute(:subscription_id, :uuid_v7)
    end
  end

  defp delivery_attributes(:bad_endpoint) do
    quote do
      uuid_primary_key(:delivery_key)
      attribute(:endpoint_id, :string, allow_nil?: false)
    end
  end

  defp delivery_attributes(:bad_subscription) do
    quote do
      uuid_primary_key(:delivery_key)
      attribute(:subscription_id, :string)
    end
  end

  defp emitter_definition(_modules, false), do: nil

  defp emitter_definition(modules, true) do
    quote do
      defmodule unquote(modules.emitter) do
        use Ash.Resource,
          domain: nil,
          data_layer: AshSqlite.DataLayer,
          validate_domain_inclusion?: false,
          extensions: [AshHooks]

        sqlite do
          table("outbound_reference_verifier_emitters")
          repo(AshHooks.Test.Repo)
        end

        attributes do
          uuid_primary_key(:emitter_key)
        end

        actions do
          defaults([:read])
        end

        webhooks do
          outbound :reference_probe do
            subscriptions(unquote(modules.subscription))
            deliveries(unquote(modules.delivery))
          end
        end
      end
    end
  end
end

defmodule AshHooks.OutboundReferenceVerifierTest do
  use ExUnit.Case, async: false

  require Spark.Test
  require AshHooks.OutboundReferenceVerifierFixtures

  import AshHooks.OutboundReferenceVerifierFixtures, only: [define_resources: 5]

  alias Ash.Resource.Info, as: ResourceInfo

  test "renamed UUIDv7 endpoint and subscription keys compile with compatible redeclared references" do
    modules = modules("ValidV7")

    errors =
      Spark.Test.dsl_errors do
        define_resources("ValidV7", :v7, :v7_compatible, :v7_compatible, true)
      end

    try do
      assert errors == []
      assert ResourceInfo.primary_key(modules.endpoint) == [:endpoint_key]
      assert ResourceInfo.primary_key(modules.subscription) == [:subscription_key]
    after
      purge(modules)
    end
  end

  test "an integer endpoint key is rejected where the subscription stores a UUID reference" do
    modules = modules("IntegerEndpoint")

    errors =
      Spark.Test.dsl_errors do
        define_resources("IntegerEndpoint", :integer, :uuid, :uuid, false)
      end

    assert_compile_error(
      errors,
      modules,
      ~r/endpoint resource.*exactly one UUID-storage-compatible primary key/is
    )
  after
    purge(modules("IntegerEndpoint"))
  end

  test "a composite endpoint key is rejected instead of being encoded into endpoint_id" do
    modules = modules("CompositeEndpoint")

    errors =
      Spark.Test.dsl_errors do
        define_resources("CompositeEndpoint", :composite, :uuid, :uuid, false)
      end

    assert_compile_error(
      errors,
      modules,
      ~r/endpoint resource.*exactly one UUID-storage-compatible primary key/is
    )
  after
    purge(modules("CompositeEndpoint"))
  end

  test "an incompatible subscription key is rejected before delivery can store subscription_id" do
    modules = modules("IntegerSubscription")

    errors =
      Spark.Test.dsl_errors do
        define_resources("IntegerSubscription", :uuid, :integer, :uuid, false)
      end

    assert_compile_error(
      errors,
      modules,
      ~r/subscription resource.*exactly one UUID-storage-compatible primary key/is
    )
  after
    purge(modules("IntegerSubscription"))
  end

  test "an explicitly redeclared subscription endpoint reference must match endpoint storage" do
    modules = modules("BadSubscriptionReference")

    errors =
      Spark.Test.dsl_errors do
        define_resources("BadSubscriptionReference", :uuid, :bad_ref, :uuid, false)
      end

    assert_compile_error(
      errors,
      modules,
      ~r/subscription.*endpoint_id.*storage type.*endpoint.*primary key/is
    )
  after
    purge(modules("BadSubscriptionReference"))
  end

  test "an explicitly redeclared delivery endpoint reference must match the joined endpoint" do
    modules = modules("BadDeliveryEndpointReference")

    errors =
      Spark.Test.dsl_errors do
        define_resources("BadDeliveryEndpointReference", :uuid, :uuid, :bad_endpoint, true)
      end

    assert_compile_error(
      errors,
      modules,
      ~r/delivery.*endpoint_id.*storage type.*endpoint.*primary key/is
    )
  after
    purge(modules("BadDeliveryEndpointReference"))
  end

  test "an explicitly redeclared delivery subscription reference must match the joined subscription" do
    modules = modules("BadDeliverySubscriptionReference")

    errors =
      Spark.Test.dsl_errors do
        define_resources(
          "BadDeliverySubscriptionReference",
          :uuid,
          :uuid,
          :bad_subscription,
          true
        )
      end

    assert_compile_error(
      errors,
      modules,
      ~r/delivery.*subscription_id.*storage type.*subscription.*primary key/is
    )
  after
    purge(modules("BadDeliverySubscriptionReference"))
  end

  test "a configured endpoint module that is not an Ash resource is rejected" do
    resource = AshHooks.OutboundReferenceVerifierTest.NonResourceEndpoint.Subscription

    errors =
      Spark.Test.dsl_errors do
        defmodule Elixir.AshHooks.OutboundReferenceVerifierTest.NonResourceEndpoint.Subscription do
          use Ash.Resource,
            domain: nil,
            data_layer: AshSqlite.DataLayer,
            validate_domain_inclusion?: false,
            extensions: [AshHooks.Subscription]

          sqlite do
            table("outbound_reference_verifier_subscriptions")
            repo(AshHooks.Test.Repo)
          end

          attributes do
            uuid_primary_key(:subscription_key)
          end

          subscription do
            endpoint_resource(String)
          end

          actions do
            defaults([:read])
          end
        end
      end

    assert [{^resource, [%Spark.Error.DslError{} = error]}] = errors

    assert Exception.message(error) =~
             ~r/endpoint resource.*exactly one UUID-storage-compatible/is
  after
    :code.purge(AshHooks.OutboundReferenceVerifierTest.NonResourceEndpoint.Subscription)
    :code.delete(AshHooks.OutboundReferenceVerifierTest.NonResourceEndpoint.Subscription)
  end

  defp assert_compile_error(errors, modules, pattern) do
    assert [{module, [%Spark.Error.DslError{} = error]}] = errors
    assert module in Map.values(modules)
    assert Exception.message(error) =~ pattern
  end

  defp modules(suffix) do
    base = Module.concat(__MODULE__, suffix)

    %{
      endpoint: Module.concat(base, Endpoint),
      subscription: Module.concat(base, Subscription),
      delivery: Module.concat(base, Delivery),
      emitter: Module.concat(base, Emitter)
    }
  end

  defp purge(modules) do
    modules
    |> Map.values()
    |> Enum.each(fn module ->
      :code.purge(module)
      :code.delete(module)
    end)
  end
end
