defmodule AshHooks.Provider.Ecwid do
  @moduledoc """
  Verifies `X-Ecwid-Webhook-Signature` per [Ecwid's published webhook contract](https://github.com/Ecwid/ecwid-api-docs/blob/master/includes/_webhooks.md#webhooks-security).

  The MAC is base64 HMAC-SHA256 of `eventCreated <> "." <> eventId`, using the
  app client secret, not the access token. **Other payload fields are unsigned.**
  Verification does not authenticate store/entity IDs or business data. As Ecwid
  directs, retrieve authoritative entity details from its API before effects;
  do not treat an accepted webhook as authoritative business data.

  `event_identity/1` uses the signed event ID, preventing a change to unsigned
  payload fields from minting a second dedup identity. No delivery-age limit is
  imposed: Ecwid retries delayed notifications. Returns `AshHooks.Provider.Event`.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}
  @impl true
  def verify_signature(_body, _ctx, secret) when not is_binary(secret) or secret == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, ctx, secret) when is_binary(body) and is_map(ctx) do
    with {:ok, %{"eventCreated" => timestamp} = payload} <- Jason.decode(body),
         true <- is_integer(timestamp) and timestamp >= 0,
         {:ok, id} <- event_identity(payload) do
      Signature.hmac(
        Integer.to_string(timestamp) <> "." <> id,
        ctx[:signature],
        secret,
        :sha256,
        :base64
      )
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}
  @impl true
  def event_identity(%{"eventId" => id}) when is_binary(id) and id != "", do: {:ok, id}

  def event_identity(%{"eventId" => id}) when is_integer(id) and id >= 0,
    do: {:ok, Integer.to_string(id)}

  def event_identity(_), do: {:error, :malformed_payload}
  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
