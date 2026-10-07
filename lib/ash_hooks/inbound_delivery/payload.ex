defmodule AshHooks.InboundDelivery.Payload do
  @moduledoc """
  A decoded inbound webhook body, stored as a JSON object or array.

  ComplyCube delivers top-level objects; HubSpot delivers batches of event
  objects. The ledger retains that decoded shape and separately stores a
  digest of the signed raw bytes. This value does not preserve the original
  wire encoding and must not be used to reconstruct bytes for verification.

  Storage uses the same JSON representation as `:map`. Maps and lists cast
  directly; a JSON-encoded binary is decoded before casting. Other decoded
  scalar values are rejected.
  """

  use Ash.Type

  @impl true
  def storage_type(_), do: :map

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, value}

  def cast_input(value, _constraints) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> cast_input(decoded, [])
      _decode_error -> :error
    end
  end

  def cast_input(_value, _constraints), do: :error

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, value}

  def cast_stored(_value, _constraints), do: :error

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(value, _constraints) when is_map(value) or is_list(value),
    do: {:ok, value}

  def dump_to_native(_value, _constraints), do: :error

  @impl true
  def apply_constraints(nil, _constraints), do: {:ok, nil}

  def apply_constraints(value, _constraints), do: {:ok, value}
end
