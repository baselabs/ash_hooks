defmodule AshHooks.OutboundDeliveryTest do
  @moduledoc """
  Ledger-surface tests for the `AshHooks.OutboundDelivery` resource
  extension — the outbound twin of InboundDeliveryTest: the injected
  attributes, the effect-once unique_delivery identity, and the machine
  primitives. Runtime/concurrency behavior lives in DispatcherTest /
  DeliveryTest.
  """

  defmodule Delivery do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.OutboundDeliveryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.OutboundDelivery]

    sqlite do
      table("outbound_delivery_test_deliveries")
      repo(AshHooks.Test.Repo)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.OutboundDeliveryTest.Delivery)
    end
  end

  use ExUnit.Case, async: false
  require Spark.Test

  alias Ash.Resource.Info

  alias AshHooks.OutboundDeliveryTest.Delivery

  describe "injected delivery attributes" do
    test "the machine fields are present with their constraints" do
      attrs = Delivery |> Info.attributes() |> Map.new(&{&1.name, &1})

      assert attrs.event_uuid.type == Ash.Type.String
      assert attrs.event_uuid.allow_nil? == false
      assert attrs.event_uuid.constraints[:max_length] == 255

      assert attrs.event_type.type == Ash.Type.String
      assert attrs.event_type.allow_nil? == false

      assert attrs.payload.type == Ash.Type.Binary
      assert attrs.payload.allow_nil? == false

      assert attrs.endpoint_id.type == Ash.Type.UUID
      assert attrs.endpoint_id.allow_nil? == false

      assert attrs.subscription_id.type == Ash.Type.UUID
      assert attrs.subscription_id.allow_nil? == true

      assert attrs.signing_mode.type == Ash.Type.Atom
      assert attrs.signing_mode.allow_nil? == true
      assert attrs.signing_mode.constraints[:one_of] == [:legacy, :dual, :standard]

      assert attrs.status.type == Ash.Type.Atom
      assert attrs.status.allow_nil? == false
      assert attrs.status.default == :pending
      assert states = attrs.status.constraints[:one_of]

      assert Enum.sort(states) ==
               Enum.sort([
                 :pending,
                 :enqueue_failed,
                 :sending,
                 :disable_pending,
                 :succeeded,
                 :failed_retryable,
                 :dead_letter
               ])

      assert attrs.attempts.type == Ash.Type.Integer
      assert attrs.attempts.allow_nil? == false
      assert attrs.attempts.default == 0
      # attempts and last_error are ORDINARY writable attributes — excluded
      # from the injected actions' accept lists only (the documented floor)
      assert attrs.attempts.writable? == true
      assert attrs.last_error.writable? == true
      assert attrs.last_error.constraints[:max_length] == 255

      for name <- [
            :dispatch_source,
            :dispatch_route,
            :attempt_token,
            :send_lease_expires_at,
            :enqueue_token,
            :enqueue_lease_expires_at,
            :endpoint_snapshot
          ] do
        assert Map.has_key?(attrs, name), "missing durable ownership field #{name}"
      end

      assert attrs.dispatch_source.allow_nil? == false
      assert attrs.dispatch_route.allow_nil? == false

      for name <- [
            :attempt_token,
            :send_lease_expires_at,
            :enqueue_token,
            :enqueue_lease_expires_at,
            :endpoint_snapshot
          ] do
        refute attrs[name].writable?
      end
    end

    test "machine-written fields accept no action input" do
      attrs = Delivery |> Info.attributes() |> Map.new(&{&1.name, &1})

      refute attrs.response_status.writable?
      refute attrs.response_snippet.writable?
      refute attrs.next_attempt_at.writable?
      assert attrs.response_snippet.constraints[:max_length] == 2048
    end

    test "the primary key is client-writable for created/duplicate classification" do
      pk = Delivery |> Info.primary_key() |> List.first()
      assert pk == :id
      assert Info.attribute(Delivery, :id).writable? == true
    end
  end

  describe "effect-once identity" do
    test "unique_delivery spans endpoint_id and event_uuid — the Oban uniqueness pair" do
      identity = Info.identity(Delivery, :unique_delivery)

      assert identity.keys == [:endpoint_id, :event_uuid]
    end
  end

  describe "primary-key creation contract" do
    test "rejects a custom primary key that dispatch cannot supply or generate" do
      result =
        try do
          Code.compile_string("""
          defmodule AshHooks.OutboundDeliveryTest.UnobtainablePrimaryKeyDelivery do
            @moduledoc false
            use Ash.Resource,
              domain: AshHooks.OutboundDeliveryTest.UnobtainableDomain,
              data_layer: Ash.DataLayer.Ets,
              extensions: [AshHooks.OutboundDelivery]

            attributes do
              attribute :host_key, :string do
                primary_key?(true)
                allow_nil?(false)
              end
            end

            actions do
              defaults([:read])
            end
          end

          defmodule AshHooks.OutboundDeliveryTest.UnobtainableDomain do
            @moduledoc false
            use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

            resources do
              resource(AshHooks.OutboundDeliveryTest.UnobtainablePrimaryKeyDelivery)
            end
          end
          """)

          create_result =
            Ash.create(
              AshHooks.OutboundDeliveryTest.UnobtainablePrimaryKeyDelivery,
              %{
                event_uuid: "msg_custom-pk",
                event_type: "order_paid",
                payload: "{}",
                endpoint_id: Ash.UUID.generate()
              },
              action: :dispatch,
              authorize?: false
            )

          {:compiled, create_result}
        rescue
          error in Spark.Error.DslError -> {:compile_error, error}
        end

      assert {:compile_error, error} = result
      assert Exception.message(error) =~ ~r/primary key.*unobtainable/is
    after
      :code.purge(AshHooks.OutboundDeliveryTest.UnobtainablePrimaryKeyDelivery)
      :code.delete(AshHooks.OutboundDeliveryTest.UnobtainablePrimaryKeyDelivery)
      :code.purge(AshHooks.OutboundDeliveryTest.UnobtainableDomain)
      :code.delete(AshHooks.OutboundDeliveryTest.UnobtainableDomain)
    end
  end

  describe "ownership-field verifier" do
    test "rejects a host-defined dispatch route with incompatible storage" do
      errors =
        Spark.Test.dsl_errors do
          defmodule Elixir.AshHooks.OutboundDeliveryTest.BadRouteDelivery do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [Elixir.AshHooks.OutboundDelivery]

            attributes do
              attribute(:dispatch_route, :integer, allow_nil?: false)
            end

            actions do
              defaults([:read])
            end
          end
        end

      assert Enum.any?(errors, fn
               {AshHooks.OutboundDeliveryTest.BadRouteDelivery, module_errors} ->
                 Enum.any?(
                   module_errors,
                   &(Exception.message(&1) =~ ~r/dispatch_route.*string/is)
                 )

               _ ->
                 false
             end)
    after
      :code.purge(AshHooks.OutboundDeliveryTest.BadRouteDelivery)
      :code.delete(AshHooks.OutboundDeliveryTest.BadRouteDelivery)
    end

    test "rejects a nullable host-defined dispatch source" do
      errors =
        Spark.Test.dsl_errors do
          defmodule Elixir.AshHooks.OutboundDeliveryTest.NullableSourceDelivery do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [Elixir.AshHooks.OutboundDelivery]

            attributes do
              attribute(:dispatch_source, :string, allow_nil?: true)
            end

            actions do
              defaults([:read])
            end
          end
        end

      assert Enum.any?(errors, fn
               {AshHooks.OutboundDeliveryTest.NullableSourceDelivery, module_errors} ->
                 Enum.any?(
                   module_errors,
                   &(Exception.message(&1) =~ ~r/dispatch_source.*allow_nil/is)
                 )

               _ ->
                 false
             end)
    after
      :code.purge(AshHooks.OutboundDeliveryTest.NullableSourceDelivery)
      :code.delete(AshHooks.OutboundDeliveryTest.NullableSourceDelivery)
    end

    test "rejects a route column too short for an opaque route identifier" do
      errors =
        Spark.Test.dsl_errors do
          defmodule Elixir.AshHooks.OutboundDeliveryTest.ShortRouteDelivery do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [Elixir.AshHooks.OutboundDelivery]

            attributes do
              attribute(:dispatch_route, :string,
                allow_nil?: false,
                default: "v1:route:unbound",
                constraints: [max_length: 255]
              )
            end

            actions do
              defaults([:read])
            end
          end
        end

      assert Enum.any?(errors, fn
               {AshHooks.OutboundDeliveryTest.ShortRouteDelivery, module_errors} ->
                 Enum.any?(
                   module_errors,
                   &(Exception.message(&1) =~ ~r/dispatch_route.*max_length.*1024/is)
                 )

               _ ->
                 false
             end)
    after
      :code.purge(AshHooks.OutboundDeliveryTest.ShortRouteDelivery)
      :code.delete(AshHooks.OutboundDeliveryTest.ShortRouteDelivery)
    end

    test "accepts the exact generated ownership-field contract" do
      errors =
        Spark.Test.dsl_errors do
          defmodule Elixir.AshHooks.OutboundDeliveryTest.ValidOwnershipDelivery do
            use Ash.Resource,
              domain: nil,
              data_layer: Ash.DataLayer.Simple,
              extensions: [Elixir.AshHooks.OutboundDelivery]

            actions do
              defaults([:read])
            end
          end
        end

      refute Enum.any?(errors, fn
               {AshHooks.OutboundDeliveryTest.ValidOwnershipDelivery, module_errors} ->
                 Enum.any?(module_errors, &(Exception.message(&1) =~ "outbound ownership field"))

               _ ->
                 false
             end)
    after
      :code.purge(AshHooks.OutboundDeliveryTest.ValidOwnershipDelivery)
      :code.delete(AshHooks.OutboundDeliveryTest.ValidOwnershipDelivery)
    end
  end

  describe "machine primitives" do
    test ":dispatch is a no-touch upsert on the unique identity (the :ingest mirror)" do
      action = Info.action(Delivery, :dispatch)

      assert action.type == :create
      assert action.upsert? == true
      assert action.upsert_identity == :unique_delivery
      assert action.upsert_fields == []
    end

    test ":dispatch accepts the delivery payload" do
      action = Info.action(Delivery, :dispatch)

      assert MapSet.new(action.accept) ==
               MapSet.new([
                 :id,
                 :event_uuid,
                 :event_type,
                 :payload,
                 :endpoint_id,
                 :subscription_id,
                 :signing_mode,
                 :dispatch_source,
                 :dispatch_route
               ])
    end

    test ":mark_enqueue_failed and :requeue are the enqueue-repair pair" do
      failed = Info.action(Delivery, :mark_enqueue_failed)
      requeue = Info.action(Delivery, :requeue)

      assert failed.type == :update
      args = Map.new(failed.arguments, &{&1.name, &1.type})
      assert args.error == Ash.Type.String

      assert requeue.type == :update
    end

    test ":mark_sending owns a UUID attempt token and finite lease" do
      action = Info.action(Delivery, :mark_sending)

      assert action.type == :update
      assert action.accept == []
      args = Map.new(action.arguments, &{&1.name, &1.type})
      assert args.attempt_token == Ash.Type.UUID
      assert args.send_lease_expires_at == Ash.Type.UtcDatetimeUsec
    end

    test ":mark_succeeded and :mark_send_failed carry the machine-written outputs" do
      succeeded = Info.action(Delivery, :mark_succeeded)
      send_failed = Info.action(Delivery, :mark_send_failed)

      assert succeeded.type == :update
      s_args = Map.new(succeeded.arguments, &{&1.name, &1.type})
      assert s_args.response_status == Ash.Type.Integer
      assert s_args.response_snippet == Ash.Type.String

      assert send_failed.type == :update
      f_args = Map.new(send_failed.arguments, &{&1.name, &1.type})
      assert f_args.error == Ash.Type.String
      assert f_args.next_attempt_at == Ash.Type.UtcDatetimeUsec
      assert f_args.dead_letter? == Ash.Type.Boolean
      assert f_args.response_status == Ash.Type.Integer
    end

    test "recovery and 410 actions expose only machine arguments" do
      assert Info.action(Delivery, :bind_dispatch_route).type == :update
      assert Info.action(Delivery, :claim_enqueue).type == :update
      assert Info.action(Delivery, :release_enqueue).type == :update
      assert Info.action(Delivery, :mark_disable_pending).type == :update
      assert Info.action(Delivery, :finalize_disable).type == :update
    end

    test ":prune is a no-input destroy" do
      action = Info.action(Delivery, :prune)

      assert action.type == :destroy
      assert action.accept == []
    end
  end
end
