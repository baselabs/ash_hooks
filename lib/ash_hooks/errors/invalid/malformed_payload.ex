defmodule AshHooks.Errors.Invalid.MalformedPayload do
  @moduledoc "The webhook payload does not have the shape the provider expects."

  use Splode.Error, fields: [:provider, :detail], class: :invalid

  def message(%{provider: provider, detail: detail})
      when not is_nil(provider) and not is_nil(detail) do
    "malformed webhook payload for provider #{inspect(provider)}: #{detail}"
  end

  def message(%{provider: provider}) when not is_nil(provider) do
    "malformed webhook payload for provider #{inspect(provider)}"
  end

  def message(_error), do: "malformed webhook payload"
end
