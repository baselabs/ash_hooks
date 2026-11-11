defmodule AshHooks.Provider.Magento2 do
  @moduledoc """
  Verifies native Adobe Commerce Webhooks signatures for Magento 2.

  Implements the [official Adobe verification example](https://developer.adobe.com/commerce/extensibility/webhooks/signature-verification):
  `x-adobe-commerce-webhook-signature` is a base64 RSA-SHA256 signature of
  the **base64-encoded raw request body**, verified with the public PEM key
  from the Webhooks configuration. Enable signature verification there first.
  Adobe's prose calls this HMAC, but its executable example uses
  `crypto.createVerify('SHA256')` with a public key; this module follows that
  asymmetric contract. Do not re-encode JSON before verification.

  The inbound `secret` source returns the public PEM key. This module does not
  implement third-party Magento extensions' shared-secret schemes; use
  `AshHooks.Provider.Hmac` with their exact emitter contract instead.
  No timestamp is signed. Returns `AshHooks.Provider.Event`.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}

  @impl true
  def verify_signature(_body, _ctx, pem) when not is_binary(pem) or pem == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, %{signature: signature}, pem)
      when is_binary(body) and is_binary(signature) do
    case Base.decode64(signature) do
      {:ok, decoded} -> Signature.rsa_sha256(Base.encode64(body), decoded, pem)
      :error -> {:error, :invalid_signature}
    end
  end

  def verify_signature(_body, _ctx, _pem), do: {:error, :invalid_signature}

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
