defmodule AshHooks.Test.EgressEvents do
  @moduledoc false

  def all do
    spans =
      for span <- [:request, :queue, :connect, :send, :recv],
          event <- [:start, :stop, :exception],
          do: [:finch, span, event]

    [
      [:ash_hooks, :egress, :start],
      [:ash_hooks, :egress, :stop],
      [:finch, :reused_connection],
      [:finch, :conn_max_idle_time_exceeded],
      [:finch, :pool_max_idle_time_exceeded]
    ] ++ spans
  end
end
