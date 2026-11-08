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
    :description,
    :payload_schema,
    :version,
    :payload_versions,
    :events,
    entities: [],
    __spark_metadata__: nil
  ]

  @type t :: %__MODULE__{
          name: atom(),
          signing_mode: :legacy | :dual | :standard,
          subscriptions: module() | nil,
          deliveries: module() | nil,
          description: String.t() | nil,
          payload_schema: term() | nil,
          version: pos_integer(),
          payload_versions: %{optional(pos_integer()) => {module(), atom()}} | nil,
          events: module() | nil,
          entities: list(),
          __spark_metadata__: term()
        }
end
