defmodule AshHooks.Provider.EasyPost do
  @moduledoc """
  Verifies EasyPost's `X-Hmac-Signature` following its [Webhook API documentation](https://docs.easypost.com/docs/webhooks#webhook-authentication)
  and official [Python `validate_webhook` implementation](https://github.com/EasyPost/easypost-python/blob/7e788d1b92272bbe4e899eab5c923e53f13df778/easypost/util.py#L118-L144).

  Pass the header value in `ctx.signature`. It must be
  `hmac-sha256-hex=<lowercase hex HMAC-SHA256 of the raw body>`. The key is the
  webhook's `webhook_secret`, Unicode NFKD-normalized and UTF-8 encoded before
  hashing, matching the official Python and [Ruby client](https://github.com/EasyPost/easypost-ruby/blob/16d18a4121be61f9e428f4a45e01c6e2f4a6b4b8/lib/easypost/util.rb#L159-L175).
  Only the secret is normalized; request bytes stay unchanged. The prefix and
  digest are case-sensitive, as in those clients. Comparisons use constant time
  behind an equal-length guard. Ingress's `previous_secret` resolver supports
  overlapping keys with the same normalization applied to each key.

  This is the API/client-library `X-Hmac-Signature` contract. The separate
  [HMAC help article](https://support.easypost.com/hc/en-us/articles/39826034964237-Webhook-HMAC-Validation)
  describes `x-hmac-signature-v2`, signing timestamp, method, path, and body
  with case-insensitive comparison. This module implements the API/SDK scheme,
  not that v2 envelope, and declares no authenticated timestamp. Use durable
  deduplication rather than `replay_window_seconds` with this provider.

  Returns `AshHooks.Provider.Event`; wrap it for application event classification
  and idempotent business actions.
  """

  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}

  @impl true
  def verify_signature(_body, _ctx, secret) when not is_binary(secret) or secret == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, %{signature: "hmac-sha256-hex=" <> mac}, secret)
      when is_binary(body) do
    case :unicode.characters_to_nfkd_binary(secret) do
      key when is_binary(key) -> Signature.hmac(body, mac, key, :sha256, :hex)
      _ -> {:error, :invalid_signature}
    end
  end

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
