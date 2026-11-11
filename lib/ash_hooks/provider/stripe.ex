defmodule AshHooks.Provider.Stripe do
  @moduledoc """
  Verifies `Stripe-Signature` according to [Stripe's webhook signature guide](https://docs.stripe.com/webhooks/signature)
  and its [reference verifier](https://github.com/stripe/stripe-python/blob/master/stripe/_webhook.py).

  `t` is the Unix-seconds timestamp; each `v1` is a lowercase-hex HMAC-SHA256
  over `timestamp <> "." <> raw_body` with the endpoint signing secret (the
  complete `whsec_...` string, not base64-decoded). Any matching `v1` supports
  overlap rotation. Other versions never verify. The default replay tolerance
  is 300 seconds, symmetric about the runtime clock; `replay_window_seconds`
  overrides it. In direct verification only, `:now_ms` can supply a test clock;
  ingress never forwards that override.

  Returns `AshHooks.Provider.Event`; wrap it to classify events and execute
  idempotent business actions. This module does not interpret API versions.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}
  @impl true
  def timestamp_header, do: "stripe-signature"
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
