defmodule AshHooks.Http.Httpc do
  @moduledoc """
  The default `AshHooks.Http` adapter: OTP's `:httpc`.

  Redirects are DISABLED (`autoredirect: false`) — `:httpc` follows them
  by default (a 303 on a POST is re-issued as GET), which would both hide
  the 3xx from the runtime's `redirect_refused` classification and bypass
  the send-time SSRF check (cross-vendor live probe). TLS verifies peers
  against the OTP CA store. Connect/receive are bounded; the Oban job
  timeout is the outer bound.
  """

  @behaviour AshHooks.Http

  @default_timeout 15_000
  @default_connect_timeout 5_000

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    method = if is_binary(method), do: String.to_atom(method), else: method

    url = String.to_charlist(url)
    ct = content_type(headers)

    headers =
      Map.new(headers)
      |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    http_options = [
      ssl: ssl_options(),
      # :httpc FOLLOWS redirects by default (a 303-on-POST is re-issued as
      # GET) — the runtime must see the 3xx itself to refuse it, and a
      # followed redirect is an SSRF bypass past the send-time check
      # (cross-vendor finding, live-probed)
      autoredirect: false,
      timeout: opts[:timeout] || @default_timeout,
      connect_timeout: opts[:connect_timeout] || @default_connect_timeout
    ]

    case :httpc.request(method, {url, headers, ct, body || ""}, http_options, []) do
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
