defmodule AshHooks.InboundDelivery.Payload do
  @moduledoc """
  A decoded inbound webhook body: a JSON object OR a JSON array.

  Vendors differ in wire shape — ComplyCube delivers top-level objects,
  HubSpot batches top-level ARRAYS of event objects — and the ledger of
  record persists what the vendor signed, not a normalized remix of it.
  Storage is identical to `:map` (jsonb / JSON text) and every value
  `Ash.Type.Map` accepts still casts: this is a strict superset whose only
  addition is the list shape. A JSON string body (the raw undecoded wire)
  is accepted and decoded, mirroring `:map`'s convenience cast.
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
