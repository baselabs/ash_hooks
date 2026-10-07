defmodule AshHooks.OutboundBindingTest do
  use ExUnit.Case, async: true

  alias AshHooks.OutboundBinding

  def callback(_row, _event), do: :ok

  test "source descriptors are deterministic and bind the endpoint resource" do
    source = OutboundBinding.source(__MODULE__, :order_paid, AshHooks.Endpoint)
    direct = OutboundBinding.direct_source(AshHooks.OutboundDelivery, AshHooks.Endpoint)

    assert source == OutboundBinding.source(__MODULE__, :order_paid, AshHooks.Endpoint)
    refute source == OutboundBinding.source(__MODULE__, :order_refunded, AshHooks.Endpoint)
    assert OutboundBinding.endpoint_resource?(source, AshHooks.Endpoint)
    assert OutboundBinding.endpoint_resource?(direct, AshHooks.Endpoint)
    refute OutboundBinding.endpoint_resource?(source, AshHooks.Subscription)
    refute OutboundBinding.endpoint_resource?("not-a-descriptor", AshHooks.Endpoint)

    non_list = "ash_hooks:" <> Base.url_encode64(Jason.encode!(%{"source" => 1}), padding: false)
    refute OutboundBinding.endpoint_resource?(non_list, AshHooks.Endpoint)
  end

  test "named callbacks and external captures normalize to one route" do
    assert {:ok, named} = OutboundBinding.route({__MODULE__, :callback}, [])
    assert {:ok, captured} = OutboundBinding.route(&__MODULE__.callback/2, [])
    assert named == captured
    assert OutboundBinding.recoverable_route?(named)
  end

  test "anonymous callbacks distinguish keyed, unresolved, and unbound routes" do
    callback = fn _row, _event -> :ok end

    assert {:ok, keyed} = OutboundBinding.route(callback, enqueue_key: "billing-v1")
    assert {:ok, ^keyed} = OutboundBinding.route(callback, enqueue_key: :"billing-v1")
    assert OutboundBinding.recoverable_route?(keyed)

    assert {:ok, unresolved} = OutboundBinding.route(callback, [])
    assert unresolved == OutboundBinding.unkeyed_route()
    refute OutboundBinding.recoverable_route?(unresolved)

    assert {:ok, unbound} = OutboundBinding.route(nil, [])
    refute OutboundBinding.recoverable_route?(unbound)
    refute unresolved == unbound
  end

  test "invalid callback and enqueue-key shapes fail explicitly" do
    callback = fn _row, _event -> :ok end

    assert {:error, :invalid_enqueuer} = OutboundBinding.route(:not_a_callback, [])
    assert {:error, :invalid_enqueue_key} = OutboundBinding.route(callback, enqueue_key: "")

    assert {:error, :invalid_enqueue_key} =
             OutboundBinding.route(callback, enqueue_key: String.duplicate("x", 513))

    assert {:error, :invalid_enqueue_key} = OutboundBinding.route(callback, enqueue_key: 42)
  end
end
