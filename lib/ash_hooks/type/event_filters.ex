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
      case filter_error(key, value, declared) do
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

  defp filter_error(key, value, declared) do
    if key_name(key) in declared do
      list_error(value)
    else
      "is not declared in filter_attributes"
    end
  end

  defp key_name(key) do
    to_string(key)
  rescue
    _ in [Protocol.UndefinedError, UnicodeConversionError, ArgumentError] -> nil
  end

  defp list_error([]), do: "must have a nonempty list for an any-of filter"
  defp list_error([_ | _] = list) when length(list) > 0, do: nil
  defp list_error([_ | _]), do: "must have a proper list for an any-of filter"
  defp list_error(_value), do: nil
end
