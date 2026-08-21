defmodule AshHooks.Provider.Mock do
  @moduledoc """
  Reference provider for tests and examples: HMAC-SHA256 over the raw body via
  the default implementation, event type from `payload["type"]`, and an
  echoing typed event.

  `parse_event_type/1` resolves the type string with `String.to_existing_atom/1`
  — fail-closed: a type that was not already an atom is reported as an unknown
  event, never converted into a newly created one (no atom-table growth from
  webhook input). The Mock imposes NO taxonomy beyond that: any pre-existing
  atom is accepted as a type (it is a general test double — real providers
  match their vendor's known type strings). JSON scalar values (`nil`, `true`,
  `false`, decoded from JSON null/true/false and from their string forms) are
  rejected as malformed, not event types.

  The optional secret callbacks are deliberately NOT implemented: the Mock
  exercises the app-level default scope, with the secret supplied by the
  consumer's DSL `secret` source.
  """

  alias AshHooks.Provider

  defmodule Event do
    @moduledoc "Typed event echoed by `AshHooks.Provider.Mock.handle_event/2`."

    defstruct [:type, :payload]

    @type t :: %__MODULE__{type: atom(), payload: map()}
  end

  @behaviour Provider

  @impl Provider
  def verify_signature(raw_body, ctx, secret) do
    Provider.default_verify_signature(raw_body, ctx.signature, secret, :hmac_sha256)
  end

  @impl Provider
  def parse_event_type(%{"type" => type}) when is_binary(type) do
    case String.to_existing_atom(type) do
      scalar when scalar in [nil, true, false] -> {:error, :malformed_payload}
      type_atom -> {:ok, type_atom}
    end
  rescue
    ArgumentError -> {:error, :unknown_event_type}
  end

  def parse_event_type(%{"type" => type})
      when is_atom(type) and type not in [nil, true, false],
      do: {:ok, type}

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  @impl Provider
  def handle_event(event_type, payload) do
    {:ok, %Event{type: event_type, payload: payload}}
  end
end
