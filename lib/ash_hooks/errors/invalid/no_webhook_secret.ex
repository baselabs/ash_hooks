defmodule AshHooks.Errors.Invalid.NoWebhookSecret do
  @moduledoc """
  The signing secret for an inbound webhook's provider is unconfigured or
  unavailable. The caller verifies nothing and does not run the handler.
  """

  use Splode.Error, fields: [:provider], class: :invalid

  def message(%{provider: provider}) when not is_nil(provider) do
    "no webhook signing secret configured for provider #{inspect(provider)}"
  end

  def message(_error), do: "no webhook signing secret configured"
end
