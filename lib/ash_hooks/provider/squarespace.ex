defmodule AshHooks.Provider.Squarespace do
  @moduledoc """
  Verifies `Squarespace-Signature` following [Squarespace's notification verification](https://commerce-apis.squarespace.com/webhooks/verifying-notifications).

  Decode the subscription's hexadecimal secret to bytes, then compare the
  lowercase-hex HMAC-SHA256 of the exact raw body. No timestamp is signed.
  Returns `AshHooks.Provider.Event`; hosts own classification and handling.
  """
  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}
  @impl true
  def verify_signature(_body, _ctx, secret) when not is_binary(secret) or secret == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, ctx, secret) when is_map(ctx) do
    case Base.decode16(secret, case: :mixed) do
      {:ok, key} -> Signature.hmac(body, ctx[:signature], key, :sha256, :hex)
      :error -> {:error, :invalid_signature}
    end
  end

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}
  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
