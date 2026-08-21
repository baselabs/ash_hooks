defmodule AshHooks.Outbound do
  @moduledoc false

  defstruct [
    :name,
    :signing_mode,
    :subscriptions,
    :deliveries,
    entities: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{}
end
