defmodule AshHooks.Http.Headers do
  @moduledoc false

  @spec validate(map() | Enumerable.t()) :: {:ok, map()} | {:error, atom()}
  def validate(headers) do
    Enum.reduce_while(headers, {:ok, %{}}, fn
      {name, value}, {:ok, acc} ->
        cond do
          not valid_name?(name) -> {:halt, {:error, :invalid_header_name}}
          not valid_value?(value) -> {:halt, {:error, :invalid_header_value}}
          true -> {:cont, {:ok, Map.put(acc, name, value)}}
        end

      _other, _acc ->
        {:halt, {:error, :invalid_header_name}}
    end)
  end

  @doc false
  @spec validate_ordered(term()) :: {:ok, [{String.t(), String.t()}]} | {:error, atom()}
  def validate_ordered(headers) when is_list(headers), do: ordered(headers, MapSet.new(), [])
  def validate_ordered(_), do: {:error, :invalid_header_name}

  defp ordered([], _seen, acc), do: {:ok, Enum.reverse(acc)}

  defp ordered([{name, value} = line | rest], seen, acc) do
    cond do
      not valid_name?(name) -> {:error, :invalid_header_name}
      not valid_value?(value) -> {:error, :invalid_header_value}
      MapSet.member?(seen, String.downcase(name, :ascii)) -> {:error, :duplicate_header}
      true -> ordered(rest, MapSet.put(seen, String.downcase(name, :ascii)), [line | acc])
    end
  end

  defp ordered(_, _, _), do: {:error, :invalid_header_name}

  defp valid_name?(name) when is_binary(name) and name != "" do
    name
    |> :binary.bin_to_list()
    |> Enum.all?(&token_byte?/1)
  end

  defp valid_name?(_name), do: false

  defp valid_value?(value) when is_binary(value) do
    String.valid?(value) and
      value
      |> String.to_charlist()
      |> Enum.all?(&(&1 > 31 and &1 not in 127..159))
  end

  defp valid_value?(_value), do: false

  defp token_byte?(byte) when byte in ?0..?9 or byte in ?A..?Z or byte in ?a..?z, do: true
  defp token_byte?(byte) when byte in ~c"!#$%&'*+-.^_`|~", do: true
  defp token_byte?(_byte), do: false
end
