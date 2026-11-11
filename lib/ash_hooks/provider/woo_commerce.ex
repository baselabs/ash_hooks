defmodule AshHooks.Provider.WooCommerce do
  @moduledoc """
  Verifies WooCommerce's `X-WC-Webhook-Signature`: base64 HMAC-SHA256 of the
  raw request body using the webhook's configured secret. See [WooCommerce's
  webhook contract](https://developer.woocommerce.com/docs/apis/rest-api/v1/webhooks/).

  This is WooCommerce's default algorithm. Store plugins can change it; such
  emitter-defined contracts use `AshHooks.Provider.Hmac`. No timestamp is signed.
  Returns `AshHooks.Provider.Event`; the host owns classification and handling.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Shopify}
  @impl true
  defdelegate verify_signature(body, ctx, secret), to: Shopify
  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
