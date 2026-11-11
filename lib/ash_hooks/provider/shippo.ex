defmodule AshHooks.Provider.Shippo do
  @moduledoc """
  Verifies `Shippo-Auth-Signature` using [Shippo's HMAC security contract](https://docs.goshippo.com/tracking/webhook-security).

  Configure the HMAC secret provisioned by Shippo's solutions team, not an API
  token. The header is `t=<seconds>,v1=<hex HMAC-SHA256(timestamp.body)>`.
  The default replay window is 300 seconds in either direction; set the inbound
  `replay_window_seconds` to override it. The replay bound is a package security
  policy added to the vendor's MAC procedure. Direct tests may pass `:now_ms`;
  ingress always uses the runtime clock. Returns `AshHooks.Provider.Event`.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}
  @impl true
  def timestamp_header, do: "shippo-auth-signature"
  @impl true
  def verify_signature(_body, _ctx, secret) when not is_binary(secret) or secret == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, ctx, secret) when is_binary(body) and is_map(ctx),
    do: Signature.timestamped(body, ctx, secret)

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}
  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
