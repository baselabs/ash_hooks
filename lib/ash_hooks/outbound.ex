defmodule AshHooks.Outbound do
  @moduledoc """
  Configuration for one outbound declaration in the `AshHooks` DSL.

  Use `AshHooks.Info.outbound/2` to inspect the resolved declaration.
  """

  defstruct [
    :name,
    :signing_mode,
    :subscriptions,
    :deliveries,
    entities: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          signing_mode: :legacy | :dual | :standard,
          subscriptions: module() | nil,
          deliveries: module() | nil,
          entities: list(),
          __spark_metadata__: term()
        }
end
