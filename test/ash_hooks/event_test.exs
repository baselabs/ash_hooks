defmodule AshHooks.EventTest do
  @moduledoc """
  The `%AshHooks.Event{}` contract: the outbound pipeline's unit of work.
  Ids follow the SW canonical-string constraints (msg_-prefixable, never
  `.`-carrying), types canonicalize to strings (the single representation
  subscriptions filter on), and the payload is the exact binary bytes to
  sign — never a re-encodable structure.
  """

  use ExUnit.Case, async: true

  alias AshHooks.Event

  @payload Jason.encode!(%{"order" => 1, "total" => 42})

  describe "new/1 id generation" do
    test "generates a msg_-prefixed id when absent" do
      assert {:ok, %Event{id: id}} = Event.new(type: :order_paid, payload: @payload)
      assert String.starts_with?(id, "msg_")
      refute String.contains?(id, ".")
    end

    test "generated ids are unique per call" do
      assert {:ok, %Event{id: a}} = Event.new(type: :order_paid, payload: @payload)
      assert {:ok, %Event{id: b}} = Event.new(type: :order_paid, payload: @payload)
      assert a != b
    end
  end

  describe "new/1 caller-supplied ids" do
    test "accepts a valid id verbatim" do
      assert {:ok, %Event{id: "msg_fixed_1"} = event} =
               Event.new(id: "msg_fixed_1", type: "order_paid", payload: @payload)

      assert event.type == "order_paid"
    end

    test "rejects an id containing a dot (the canonical-string delimiter)" do
      assert {:error, reason} = Event.new(id: "msg_evil.id", type: :order_paid, payload: @payload)
      assert reason =~ "dot"
    end

    test "rejects an empty id" do
      assert {:error, _reason} = Event.new(id: "", type: :order_paid, payload: @payload)
    end

    test "rejects a non-binary id" do
      assert {:error, _reason} = Event.new(id: 123, type: :order_paid, payload: @payload)
    end
  end

  describe "new/1 type canonicalization" do
    test "stringifies an atom type" do
      assert {:ok, %Event{type: "order_paid"}} = Event.new(type: :order_paid, payload: @payload)
    end

    test "keeps a binary type verbatim" do
      assert {:ok, %Event{type: "order.paid" = kept}} =
               Event.new(type: "order.paid", payload: @payload)

      assert kept == "order.paid"
    end

    test "rejects a missing type" do
      assert {:error, _reason} = Event.new(payload: @payload)
    end
  end

  describe "new/1 payload" do
    test "rejects a non-binary payload (no re-encodable structures)" do
      assert {:error, reason} = Event.new(type: :order_paid, payload: %{"order" => 1})
      assert reason =~ "binary"
    end

    test "rejects a missing payload" do
      assert {:error, _reason} = Event.new(type: :order_paid)
    end
  end

  describe "new/1 metadata" do
    test "defaults to an empty map" do
      assert {:ok, %Event{metadata: %{}}} = Event.new(type: :order_paid, payload: @payload)
    end

    test "accepts a map" do
      assert {:ok, %Event{metadata: %{tenant: "t1"}}} =
               Event.new(type: :order_paid, payload: @payload, metadata: %{tenant: "t1"})
    end

    test "rejects a non-map metadata" do
      assert {:error, _reason} =
               Event.new(type: :order_paid, payload: @payload, metadata: :oops)
    end
  end
end
