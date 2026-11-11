defmodule AshHooks.Inbound do
  @moduledoc """
  Configuration for one inbound webhook declaration.

  Values are built by the `AshHooks` DSL and exposed through
  `AshHooks.Info.inbound/2`; applications do not construct this struct
  directly.
  """

  defstruct [
    :name,
    :provider,
    :body_format,
    :secret,
    :previous_secret,
    :paused,
    :event_id,
    :replay_window_seconds,
    entities: [],
    __spark_metadata__: nil
  ]

  @typedoc "A compiled inbound webhook declaration."
  @type t :: %__MODULE__{
          name: atom(),
          provider: module() | nil,
          body_format: :json | :form | nil,
          secret: term(),
          previous_secret: term(),
          paused: term(),
          event_id: (map() | list() -> term()) | nil,
          replay_window_seconds: non_neg_integer() | nil,
          entities: list(),
          __spark_metadata__: term()
        }
end
