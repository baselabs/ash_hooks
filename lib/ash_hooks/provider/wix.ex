defmodule AshHooks.Provider.Wix do
  @moduledoc """
  Verifies Wix's native RS256 JWT webhook body with the app's public PEM key.

  See [Wix's webhook delivery contract](https://dev.wix.com/docs/build-apps/develop-your-app/api-integrations/events-and-webhooks/about-webhooks)
  and [event structure](https://dev.wix.com/docs/api-reference/articles/work-with-wix-apis/platform/about-the-structure-of-webhooks).
  The raw HTTP body is a compact signed JWT, not JSON with a separate HMAC
  header. The inbound `secret` source returns the trusted public key from the
  app dashboard. `signature_source/0` admits this body-only signature; ingress
  does not need `ctx.signature`. No keys or algorithms are obtained from the
  request. Only RS256 is accepted; unknown critical headers fail closed.

  Present `exp` and `nbf` claims are enforced. No age limit is invented for
  JWTs lacking expiration: Wix can delay/redeliver notifications. Direct tests
  may pass `:now_ms`; ingress always uses the runtime clock.

  `decode_payload/1` preserves all signed JWT claims, including the `data`
  envelope and its JSON-string fields. It is a decoder, not authentication;
  ingress calls it only after verification. The ledger digest binds the raw
  JWT. Returns `AshHooks.Provider.Event`; hosts own business handling.
  """

  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}

  @impl true
  def signature_source, do: :body

  @impl true
  def verify_signature(_body, _ctx, pem) when not is_binary(pem) or pem == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, ctx, pem) when is_binary(body) and is_map(ctx) do
    with {:ok, header, claims, signature, input} <- parts(body),
         :ok <- check_header(header),
         :ok <- Signature.rsa_sha256(input, signature, pem) do
      check_times(claims, ctx)
    else
      _ -> {:error, :invalid_signature}
    end
  rescue
    _ -> {:error, :invalid_signature}
  end

  def verify_signature(_body, _ctx, _pem), do: {:error, :invalid_signature}

  defp parts(body) do
    with [header, payload, signature] <- String.split(body, "."),
         {:ok, header_bytes} <- Base.url_decode64(header, padding: false),
         {:ok, payload_bytes} <- Base.url_decode64(payload, padding: false),
         {:ok, signature_bytes} <- Base.url_decode64(signature, padding: false),
         {:ok, header_data} when is_map(header_data) <- Jason.decode(header_bytes),
         {:ok, claims} when is_map(claims) <- Jason.decode(payload_bytes) do
      {:ok, header_data, claims, signature_bytes, header <> "." <> payload}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp check_header(%{"alg" => "RS256"} = header) do
    if Map.get(header, "crit", []) == [] and Map.get(header, "b64", true) == true,
      do: :ok,
      else: {:error, :invalid_signature}
  end

  defp check_header(_), do: {:error, :invalid_signature}

  defp check_times(claims, ctx) do
    now = div(ctx[:now_ms] || System.system_time(:millisecond), 1000)

    with :ok <- check_time(Map.fetch(claims, "exp"), now, :exp),
         do: check_time(Map.fetch(claims, "nbf"), now, :nbf)
  end

  defp check_time(:error, _now, _kind), do: :ok

  defp check_time({:ok, time}, _now, _kind) when not is_number(time),
    do: {:error, :invalid_signature}

  defp check_time({:ok, time}, now, :exp) when now >= time, do: {:error, :stale_timestamp}
  defp check_time({:ok, time}, now, :nbf) when now < time, do: {:error, :stale_timestamp}
  defp check_time(_time, _now, _kind), do: :ok

  @impl true
  def decode_payload(body) do
    case parts(body) do
      {:ok, _header, claims, _signature, _input} -> {:ok, claims}
      error -> error
    end
  end

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
