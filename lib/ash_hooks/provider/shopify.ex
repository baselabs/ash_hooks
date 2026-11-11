defmodule AshHooks.Provider.Shopify do
  @moduledoc """
  Verifies Shopify's `X-Shopify-Hmac-Sha256`, the base64 HMAC-SHA256 of the
  exact raw body using the app client secret. See [Shopify's delivery verification](https://shopify.dev/docs/apps/build/webhooks/verify-deliveries).

  No timestamp is signed. Returns `AshHooks.Provider.Event`; the host owns
  event classification and idempotent business actions. Topic and delivery ID
  headers are outside this MAC and must not be treated as signed body fields.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}
  @impl true
  def verify_signature(body, ctx, secret) when is_map(ctx),
    do: Signature.hmac(body, ctx[:signature], secret, :sha256, :base64)

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}
  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
