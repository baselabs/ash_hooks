defmodule AshHooks.Errors.Invalid.InvalidSignature do
  @moduledoc "An inbound webhook's signature did not verify under the provider's scheme."

  use Splode.Error, fields: [:provider], class: :invalid

  def message(%{provider: provider}) when not is_nil(provider) do
    "webhook signature verification failed for provider #{inspect(provider)}"
  end

  def message(_error), do: "webhook signature verification failed"
end
