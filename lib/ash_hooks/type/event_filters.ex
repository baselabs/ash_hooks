defmodule AshHooks.Type.EventFilters do
  @moduledoc false
  use Ash.Type.NewType, subtype_of: :map

  @impl Ash.Type
  def constraints do
    Keyword.put(super(), :keys, type: {:list, :atom}, default: [])
  end

  @impl Ash.Type
  def cast_input(value, constraints) do
    case Ash.Type.Map.cast_input(value, []) do
      {:ok, filters} -> apply_constraints(filters, constraints)
      :error -> {:error, "event_filters must be nil or a plain map"}
    end
  end

  @impl Ash.Type
  def apply_constraints(nil, _constraints), do: {:ok, nil}

  def apply_constraints(filters, constraints) when is_map(filters) and not is_struct(filters) do
    declared = MapSet.new(constraints[:keys] || [], &to_string/1)

    Enum.reduce_while(filters, {:ok, filters}, fn {key, value}, valid ->
      case filter_error(key, value, filters, declared) do
        nil -> {:cont, valid}
        reason -> {:halt, {:error, "filter key #{inspect(key)} #{reason}"}}
      end
    end)
  end

  def apply_constraints(_filters, _constraints),
    do: {:error, "event_filters must be nil or a plain map"}

  @impl Ash.Type
  def cast_atomic(value, constraints) do
    if Ash.Expr.expr?(value), do: {:atomic, value}, else: cast_input(value, constraints)
  end

  @impl Ash.Type
  def apply_atomic_constraints(value, constraints) do
    if Ash.Expr.expr?(value), do: {:ok, value}, else: apply_constraints(value, constraints)
  end

  defp filter_error(key, value, filters, declared) do
    cond do
      not (is_atom(key) or is_binary(key)) ->
        "must be a string or atom"

      to_string(key) not in declared ->
        "is not declared in filter_attributes"

      is_atom(key) and Map.has_key?(filters, to_string(key)) ->
        "has a duplicate string key"

      value == [] ->
        "must have a nonempty list for an any-of filter"

      true ->
        text_error(to_string(key)) || json_error(value)
    end
  end

  defp json_error(value) when is_binary(value), do: text_error(value)
  defp json_error(value) when is_number(value) or is_boolean(value) or is_nil(value), do: nil
  defp json_error([]), do: nil
  defp json_error([head | tail]), do: json_error(head) || list_error(tail)

  defp json_error(value) when is_map(value) and not is_struct(value) do
    Enum.find_value(value, fn
      {key, item} when is_binary(key) -> text_error(key) || json_error(item)
      {_key, _item} -> "must have string keys in nested maps"
    end)
  end

  defp json_error(_value), do: "must have a JSON-compatible value"

  defp list_error([]), do: nil
  defp list_error([head | tail]), do: json_error(head) || list_error(tail)
  defp list_error(_tail), do: "must have a proper list"

  defp text_error(value) do
    cond do
      not String.valid?(value) -> "must contain valid UTF-8"
      String.contains?(value, <<0>>) -> "must not contain NUL"
      true -> nil
    end
  end
end
