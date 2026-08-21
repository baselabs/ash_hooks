defmodule AshHooks.Errors.Invalid.UnknownEventType do
  @moduledoc "The payload's event type is not one the provider knows."

  use Splode.Error, fields: [:provider, :event_type], class: :invalid

  def message(%{provider: provider, event_type: event_type})
      when not is_nil(provider) and not is_nil(event_type) do
    "unknown event type #{inspect(event_type)} for provider #{inspect(provider)}"
  end

  def message(%{event_type: event_type}) when not is_nil(event_type) do
    "unknown event type #{inspect(event_type)}"
  end

  def message(_error), do: "unknown webhook event type"
end
