defmodule AshHooks.Provider.BigCommerce do
  @moduledoc """
  Verifies BigCommerce's [HTTPS Standard Webhooks contract](https://docs.bigcommerce.com/developer/docs/beta/webhooks/http-webhooks#webhook-signature).

  Supply the raw app client secret. BigCommerce's sample base64-encodes those
  bytes for the Standard Webhooks verifier; this module performs that encoding.
  Required headers are `webhook-id`, `webhook-timestamp`, and
  `webhook-signature`. The signed input is `id.timestamp.raw_body`.
  The payload's `hash` is not a signature. Older custom `X-BC-Signature`
  emitter contracts must use a host-configured `AshHooks.Provider.Hmac` instead.

  Tolerance defaults to 300 seconds; `replay_window_seconds` overrides it.
  Direct tests may pass `:now_ms`; ingress uses the runtime clock.
  Returns `AshHooks.Provider.Event`; hosts own classification and handling.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.Event
  @impl true
  def timestamp_header, do: "webhook-timestamp"
  @impl true
  def verify_signature(_body, _ctx, secret) when not is_binary(secret) or secret == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, %{headers: headers} = ctx, secret)
      when is_binary(body) and is_map(headers) do
    opts = [
      now: div(ctx[:now_ms] || System.system_time(:millisecond), 1000),
      tolerance: ctx[:replay_window_seconds] || 300
    ]

    case AshHooks.Signing.verify(body, headers, "whsec_" <> Base.encode64(secret), opts) do
      {:ok, _} -> :ok
      {:error, :timestamp_out_of_tolerance} -> {:error, :stale_timestamp}
      {:error, _} -> {:error, :invalid_signature}
    end
  end

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}
  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
