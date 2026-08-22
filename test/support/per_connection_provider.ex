defmodule AshHooks.TestPerConnectionProvider do
  @moduledoc false
  # Compile-time fixture with a beam on disk, so the code-server tests can
  # purge/delete it and observe the not-yet-loaded resolution path.

  @behaviour AshHooks.Provider

  def webhook_secret_scope, do: :per_connection
  def verify_signature(_raw_body, _ctx, _secret), do: :ok
  def parse_event_type(_payload), do: {:ok, :checked}

  def handle_event(event_type, payload),
    do: {:ok, %AshHooks.Event{type: event_type, payload: payload}}
end
