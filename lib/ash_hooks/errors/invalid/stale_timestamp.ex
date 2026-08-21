defmodule AshHooks.Errors.Invalid.StaleTimestamp do
  @moduledoc """
  The timestamp carried by a windowed provider's signature falls outside the
  allowed replay window.
  """

  use Splode.Error, fields: [:provider], class: :invalid

  def message(%{provider: provider}) when not is_nil(provider) do
    "webhook timestamp is outside the replay window for provider #{inspect(provider)}"
  end

  def message(_error), do: "webhook timestamp is outside the replay window"
end
