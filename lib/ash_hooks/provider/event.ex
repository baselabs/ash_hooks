defmodule AshHooks.Provider.Event do
  @moduledoc """
  A verified webhook from a signature-only built-in provider.

  Its `type` is the fixed atom `:webhook`; vendor event names remain in the
  payload, never converted into atoms. Wrap the provider with your own
  `AshHooks.Provider` to classify events and perform idempotent business actions.
  """

  defstruct [:type, :payload]

  @type t :: %__MODULE__{type: atom(), payload: map() | list()}

  @doc false
  def parse(payload) when is_map(payload) or is_list(payload), do: {:ok, :webhook}
  def parse(_payload), do: {:error, :malformed_payload}

  @doc false
  def build(type, payload), do: {:ok, %__MODULE__{type: type, payload: payload}}
end
