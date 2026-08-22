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
                 :signing_mode
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

    test ":mark_sending takes no input (attempts bumps in-statement)" do
      action = Info.action(Delivery, :mark_sending)

      assert action.type == :update
      assert action.accept == []
      assert action.arguments == []
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

    test ":prune is a no-input destroy" do
      action = Info.action(Delivery, :prune)

      assert action.type == :destroy
      assert action.accept == []
    end
  end
end
