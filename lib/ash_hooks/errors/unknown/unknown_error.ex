defmodule AshHooks.Errors.Unknown.UnknownError do
  @moduledoc "An error ash_hooks did not recognize."

  use Splode.Error, fields: [:error], class: :unknown

  def message(%{error: error}) when is_exception(error), do: Exception.message(error)
  def message(%{error: error}) when is_binary(error), do: error
  def message(%{error: error}), do: inspect(error)
end
