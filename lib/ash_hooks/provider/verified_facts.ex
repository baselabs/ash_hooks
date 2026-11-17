defmodule AshHooks.Provider.VerifiedFacts do
  @moduledoc false

  def valid?(facts) when is_map(facts) and not is_struct(facts) do
    with true <- json?(facts, 0),
         {:ok, bytes} <- Jason.encode(facts) do
      byte_size(bytes) <= 8 * 1024
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  def valid?(_), do: false

  defp json?(_, depth) when depth > 8, do: false
  defp json?(value, _) when is_binary(value), do: String.valid?(value)
  defp json?(value, _) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth + 1))

  defp json?(value, depth) when is_map(value) and not is_struct(value) do
    Enum.all?(value, fn {key, item} ->
      is_binary(key) and String.valid?(key) and json?(item, depth + 1)
    end)
  end

  defp json?(_, _), do: false
end
