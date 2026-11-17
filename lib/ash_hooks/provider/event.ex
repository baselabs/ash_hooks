defmodule AshHooks.Provider.Event do
  @moduledoc """
  A verified webhook returned by a configured provider's default handler.

  Its `type` is the fixed atom `:webhook`; the sender's event names remain in the
  payload, never converted into atoms. Override `parse_event_type/1` and
  `handle_event/2` in your provider to classify events and perform idempotent
  business actions.
  """

  defstruct [:type, :payload]

  @type t :: %__MODULE__{type: atom(), payload: map() | list()}

  @doc """
  Classifies a decoded map or list as `:webhook` without creating atoms from
  sender-controlled names. Other values return `{:error, :malformed_payload}`.
  Use this as a provider's `parse_event_type/1` callback when the host does not
  need domain-specific classification.
  """
  @spec parse(term()) :: {:ok, :webhook} | {:error, :malformed_payload}
  def parse(payload) when is_map(payload) or is_list(payload), do: {:ok, :webhook}
  def parse(_payload), do: {:error, :malformed_payload}

  @doc """
  Wraps a verified, decoded payload and the host's classified event type in
  an event. Returns `{:ok, event}` without performing verification or business
  effects. The caller owns type and payload validation. A provider can delegate
  `handle_event/2` here when it only needs to return the event.
  """
  @spec build(atom(), map() | list()) :: {:ok, t()}
  def build(type, payload), do: {:ok, %__MODULE__{type: type, payload: payload}}
end
