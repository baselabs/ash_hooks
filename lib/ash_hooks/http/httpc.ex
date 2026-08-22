defmodule AshHooks.Http.Httpc do
  @moduledoc """
  The default `AshHooks.Http` adapter: OTP's `:httpc`.

  `:httpc` NEVER follows redirects natively — a 3xx returns as a response
  and the runtime classifies it `redirect_refused` (the spec's "redirects
  refused" is the platform default, not a workaround). TLS verifies peers
  against the OTP CA store. Connect/receive are bounded (`:timeout` /
  `:connect_timeout`); the Oban job timeout is the outer bound.
  """

  @behaviour AshHooks.Http

  @default_timeout 15_000
  @default_connect_timeout 5_000

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    request = {
      method |> to_charlist() |> String.to_atom() |> then(&if &1 == :post, do: :post, else: &1),
      String.to_charlist(url),
      Enum.map(headers, fn {name, value} ->
        {String.to_charlist(name), String.to_charlist(value)}
      end),
      content_type(headers),
      body || ""
    }

    http_options = [
      ssl: ssl_options(),
      timeout: opts[:timeout] || @default_timeout,
      connect_timeout: opts[:connect_timeout] || @default_connect_timeout
    ]

    case :httpc.request(request, http_options) do
      {:ok, {{_version, status, _phrase}, resp_headers, resp_body}} ->
        {:ok,
         %{
           status: status,
           headers:
             Enum.map(resp_headers, fn {name, value} -> {to_string(name), to_string(value)} end),
           body: resp_body && to_string(resp_body)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp content_type(headers) do
    case Map.get(headers, "content-type") do
      ct when is_binary(ct) -> String.to_charlist(ct)
      _ -> ~c"application/json"
    end
  end

  defp ssl_options do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3
    ]
  end
end
