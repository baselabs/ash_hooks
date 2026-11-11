defmodule AshHooks.Provider.Twilio do
  @moduledoc """
  Twilio's `X-Twilio-Signature`: base64 HMAC-SHA1 using the account Auth Token.

  Implements [Twilio's request validation](https://www.twilio.com/docs/usage/webhooks/webhooks-security).
  Supply the exact public URL, including its encoded query, in `:request_uri`.
  Form requests append sorted parameter names and their sorted unique values
  to that URL. No form fields are selected or discarded; bracket names remain
  literal. JSON requests instead bind the raw body's SHA-256 through the URL's
  `bodySHA256` parameter and sign the URL alone. Query parameters are never
  appended as form fields. Raw bytes remain unchanged in ingress.

  No authenticated timestamp is provided. Use durable deduplication. The handler
  returns `AshHooks.Provider.Event`; wrap it to implement application actions.
  """

  @behaviour AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}

  @impl true
  def verify_signature(_body, _ctx, secret) when not is_binary(secret) or secret == "",
    do: {:error, :no_webhook_secret}

  def verify_signature(body, %{signature: signature, request_uri: uri}, secret)
      when is_binary(body) and is_binary(signature) and is_binary(uri) do
    with true <- String.valid?(uri),
         {:ok, %URI{scheme: scheme, host: host} = parsed} <- URI.new(uri),
         true <- scheme in ["http", "https"] and is_binary(host) and host != "",
         {:ok, signed} <- signed_payload(body, uri, parsed.query) do
      Signature.hmac(signed, signature, secret, :sha, :base64)
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def verify_signature(_body, _ctx, _secret), do: {:error, :invalid_signature}

  defp signed_payload(body, uri, query) do
    hashes = for {"bodySHA256", hash} <- URI.query_decoder(query || ""), do: hash

    case hashes do
      [] ->
        {:ok, uri <> form_suffix(body)}

      [hash] ->
        case Signature.compare(Base.encode16(:crypto.hash(:sha256, body), case: :lower), hash) do
          :ok -> {:ok, uri}
          error -> error
        end

      _ ->
        {:error, :invalid_signature}
    end
  end

  defp form_suffix(body) do
    body
    |> URI.query_decoder()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, values} ->
      values |> Enum.uniq() |> Enum.sort() |> Enum.map(&[name, &1])
    end)
    |> IO.iodata_to_binary()
  end

  @impl true
  def decode_payload(body) do
    case Jason.decode(body) do
      {:ok, payload} when is_map(payload) or is_list(payload) -> {:ok, payload}
      _ -> AshHooks.Provider.decode_body(body, :form)
    end
  end

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
