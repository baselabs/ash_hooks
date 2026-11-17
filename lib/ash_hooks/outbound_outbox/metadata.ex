defmodule AshHooks.OutboundOutbox.Metadata do
  @moduledoc false

  @max_depth 32
  @max_bytes 1_048_576
  @integer_min -9_223_372_036_854_775_808
  @integer_max 9_223_372_036_854_775_807

  def validate(metadata) do
    if is_map(metadata) and valid?(metadata, 0) and encoded_size?(metadata),
      do: :ok,
      else: {:error, :invalid_publication_metadata}
  end

  defp valid?(_value, depth) when depth > @max_depth, do: false
  defp valid?(value, _depth) when value in [nil, true, false], do: true

  defp valid?(value, _depth) when is_integer(value),
    do: value >= @integer_min and value <= @integer_max

  defp valid?(value, _depth) when is_float(value) do
    <<sign::1, exponent::11, mantissa::52>> = <<value::float>>
    not (sign == 1 and exponent == 0 and mantissa == 0)
  end

  defp valid?(value, _depth) when is_binary(value), do: string?(value)
  defp valid?(value, depth) when is_list(value), do: Enum.all?(value, &valid?(&1, depth + 1))
  defp valid?(%{__struct__: _}, _depth), do: false

  defp valid?(value, depth) when is_map(value),
    do: Enum.all?(value, fn {key, item} -> string?(key) and valid?(item, depth + 1) end)

  defp valid?(_value, _depth), do: false

  defp string?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  defp string?(_value), do: false

  defp encoded_size?(metadata), do: byte_size(Jason.encode!(metadata)) <= @max_bytes
end
