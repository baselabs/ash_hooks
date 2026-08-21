defmodule AshHooks.Inbound do
  @moduledoc false

  defstruct [:name, :secret, :event_id, :replay_window_seconds, entities: [], __spark_metadata__: nil]

  @type t :: %__MODULE__{}
end
