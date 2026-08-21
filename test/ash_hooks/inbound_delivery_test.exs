defmodule AshHooks.InboundDeliveryTest do
  @moduledoc """
  Ledger-surface tests for the `AshHooks.InboundDelivery` resource extension:
  the injected attributes, the scoped unique-ingest identity, and the fenced
  actions. Runtime/concurrency behavior lives in IngressTest.
  """

  defmodule Ledger do
    @moduledoc false
    use Ash.Resource,
      domain: AshHooks.InboundDeliveryTest.Domain,
      data_layer: AshSqlite.DataLayer,
      extensions: [AshHooks.InboundDelivery]

    sqlite do
      table("inbound_delivery_test_ledgers")
      repo(AshHooks.Test.Repo)
    end

    inbound_delivery do
      scope_identity([:account_id])
    end

    attributes do
      attribute(:account_id, :string, allow_nil?: false)
    end

    actions do
      defaults([:read])
    end
  end

  defmodule Domain do
    @moduledoc false
    use Ash.Domain, otp_app: nil, validate_config_inclusion?: false

    resources do
      resource(AshHooks.InboundDeliveryTest.Ledger)
    end
  end

  use ExUnit.Case, async: false

  alias Ash.Resource.Info
  alias Spark.Dsl.Extension

  alias AshHooks.InboundDelivery.Payload

  alias AshHooks.InboundDeliveryTest.Ledger

  describe "injected ledger attributes" do
    test "the fenced-machine fields are present with their constraints" do
      attrs = Ledger |> Info.attributes() |> Map.new(&{&1.name, &1})

      assert attrs.provider.type == Ash.Type.Atom
      assert attrs.provider.allow_nil? == false

      assert attrs.external_event_id.type == Ash.Type.String
      assert attrs.external_event_id.allow_nil? == false

      assert attrs.external_event_type.type == Ash.Type.String
      assert attrs.external_event_type.allow_nil? == true

      assert attrs.payload.type == AshHooks.InboundDelivery.Payload
      assert attrs.payload.allow_nil? == false

      assert attrs.payload_digest.type == Ash.Type.String
      assert attrs.payload_digest.allow_nil? == false

      assert attrs.status.type == Ash.Type.Atom
      assert attrs.status.allow_nil? == false
      assert attrs.status.default == :received
      assert states = attrs.status.constraints[:one_of]
      assert :received in states
      assert :claimed in states
      assert :processed in states
      assert :failed_retryable in states
      assert :failed_permanent in states

      assert attrs.fencing_token.type == Ash.Type.Integer
      assert attrs.fencing_token.allow_nil? == false
      assert attrs.fencing_token.default == 0

      assert attrs.lease_expires_at.type == Ash.Type.UtcDatetimeUsec
      assert attrs.lease_expires_at.allow_nil? == true

      assert attrs.error_class.type == Ash.Type.String
      assert attrs.error_class.allow_nil? == true

      assert attrs.attempts.type == Ash.Type.Integer
      assert attrs.attempts.allow_nil? == false
      assert attrs.attempts.default == 0
    end

    test "the primary key is client-writable for created/duplicate classification" do
      pk = Ledger |> Info.primary_key() |> List.first()
      assert pk == :id
      assert Info.attribute(Ledger, :id).writable? == true
    end
  end

  describe "payload type (map | list — batch vendors deliver arrays)" do
    test "casts maps and lists through input, native, and stored boundaries" do
      map = %{"type" => "check.completed"}
      list = [%{"subscriptionType" => "contact.creation"}]

      for value <- [map, list] do
        assert {:ok, ^value} = Payload.cast_input(value, [])
        assert {:ok, ^value} = Payload.dump_to_native(value, [])
        assert {:ok, ^value} = Payload.cast_stored(value, [])
      end
    end

    test "casts a JSON string body (the raw wire) — objects and arrays" do
      assert {:ok, [%{"a" => 1}]} = Payload.cast_input(~s([{"a":1}]), [])
      assert {:ok, %{"a" => 1}} = Payload.cast_input(~s({"a":1}), [])
    end

    test "a NON-JSON string is a cast error, never a crash (Jason returns a tagged error tuple)" do
      assert :error = Payload.cast_input("not json", [])
    end

    test "scalars and nil follow :map semantics" do
      assert {:ok, nil} = Payload.cast_input(nil, [])
      assert :error = Payload.cast_input(42, [])
      assert :error = Payload.cast_input("plain string", [])
    end
  end

  describe "unique-ingest identity" do
    test "spans provider, external event id, and declared scope slots" do
      identity = Info.identity(Ledger, :unique_ingest)

      assert identity.keys == [:provider, :external_event_id, :account_id]
    end
  end

  describe "fenced actions" do
    test ":ingest is a no-touch upsert on the unique identity" do
      action = Info.action(Ledger, :ingest)

      assert action.type == :create
      assert action.upsert? == true
      assert action.upsert_identity == :unique_ingest
      assert action.upsert_fields == []
    end

    test ":ingest accepts the ledger payload plus scope slots" do
      action = Info.action(Ledger, :ingest)

      assert MapSet.new(action.accept) ==
               MapSet.new([
                 :id,
                 :provider,
                 :external_event_id,
                 :external_event_type,
                 :payload,
                 :payload_digest,
                 :account_id
               ])
    end

    test ":claim takes the lease as an argument and bumps token and attempts" do
      action = Info.action(Ledger, :claim)

      assert action.type == :update
      args = Map.new(action.arguments, &{&1.name, &1.type})
      assert args.lease_expires_at == Ash.Type.UtcDatetimeUsec
    end

    test ":mark_failed classifies retryable vs permanent" do
      action = Info.action(Ledger, :mark_failed)

      assert action.type == :update
      args = Map.new(action.arguments, &{&1.name, &1.type})
      assert args.error_class == Ash.Type.String
      assert args.permanent? == Ash.Type.Boolean
    end

    test ":mark_processed and :renew exist as update primitives" do
      assert Info.action(Ledger, :mark_processed).type == :update
      assert Info.action(Ledger, :renew).type == :update
    end
  end

  describe "lease defaults" do
    test "defaults to 30 seconds" do
      assert Extension.get_opt(Ledger, [:inbound_delivery], :lease_seconds, nil) == 30
    end
  end

  describe "scope-slot verifier (fail-closed)" do
    test "a scope slot that is not an attribute fails compilation" do
      assert_raise Spark.Error.DslError, ~r/scope_identity/, fn ->
        defmodule BadLedger do
          @moduledoc false
          use Ash.Resource,
            domain: AshHooks.InboundDeliveryTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshHooks.InboundDelivery]

          inbound_delivery do
            scope_identity([:ghost_slot])
          end

          actions do
            defaults([:read])
          end
        end
      end
    end

    test "a nullable scope slot fails compilation" do
      assert_raise Spark.Error.DslError, ~r/allow_nil/, fn ->
        defmodule NullableSlotLedger do
          @moduledoc false
          use Ash.Resource,
            domain: AshHooks.InboundDeliveryTest.Domain,
            data_layer: Ash.DataLayer.Ets,
            extensions: [AshHooks.InboundDelivery]

          inbound_delivery do
            scope_identity([:account_id])
          end

          attributes do
            attribute(:account_id, :string)
          end

          actions do
            defaults([:read])
          end
        end
      end
    end
  end
end
