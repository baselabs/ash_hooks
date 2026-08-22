defmodule AshHooks.Http.Httpc do
  @moduledoc """
  The default `AshHooks.Http` adapter: OTP's `:httpc`, hardened.

  **IP pinning (closes the DNS-rebinding TOCTOU):** the hostname is
  resolved ONCE through `AshHooks.Ssrf.resolve_public/1` (every answer
  must be public), and the connection is made to the VALIDATED address —
  not the hostname again. TLS keeps verifying the certificate against the
  ORIGINAL hostname (SNI + hostname check), and the `host` header carries
  the original host, so receivers and cert chains are unchanged while the
  validate-then-connect gap disappears.

  **Bounded body (memory DoS floor):** the response is read as a STREAM
  (`:httpc` streams only 200/206 — every other status arrives as the
  complete result message) and accumulation stops at `:max_body_bytes`
  (default 64 KiB); the remainder is cancelled. Residual, documented: a
  hostile NON-2xx giant body is assembled inside `:httpc` before delivery
  (the client's API offers no earlier cut for the transparent path) — the
  window is narrowed from every response to error-status responses.

  Redirects are DISABLED (`autoredirect: false` — a 303-on-POST is
  otherwise re-issued as GET and the target's body returned). TLS
  verifies peers against the OTP CA store. Connect/receive are bounded;
  the Oban job timeout is the outer bound.
  """

  @behaviour AshHooks.Http

  @default_timeout 15_000
  @default_connect_timeout 5_000
  @default_max_body_bytes 65_536

  @impl true
  def request(method, url, headers, body, opts \\ []) do
    method = if is_binary(method), do: String.to_atom(method), else: method
    headers = Map.new(headers)

    resolve =
      if opts[:validate_destination] == false,
        do: &bypass_resolution/1,
        else: &AshHooks.Ssrf.resolve_public/1

    case resolve.(url) do
      {:ok, %{uri: uri, addresses: [address | _]}} ->
        pinned_request(method, uri, address, headers, body, opts)

      {:error, :unsafe} ->
        {:error, :unsafe_destination}

      {:error, :unresolvable} ->
        {:error, :unresolved_host}
    end
  end

  # Test seam ONLY (local listeners are loopback — resolve_public would
  # refuse them): the SSRF obligation lives in the DRIVER's send-time
  # check; this adapter's own resolution is defense-in-depth.
  defp bypass_resolution(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        case lookup(host) do
          {:ok, address} -> {:ok, %{uri: uri, addresses: [address]}}
          {:error, _} -> {:error, :unresolvable}
        end

      _other ->
        {:error, :unsafe}
    end
  end

  defp lookup(host) do
    bare =
      case host do
        "[" <> rest -> String.trim_trailing(rest, "]")
        plain -> plain
      end

    case :inet.parse_address(String.to_charlist(bare)) do
      {:ok, literal} -> {:ok, literal}
      {:error, _} -> :inet.getaddr(String.to_charlist(bare), :inet)
    end
  end

  defp pinned_request(method, uri, address, headers, body, opts) do
    host = String.downcase(uri.host)
    port = uri.port || default_port(uri.scheme)
    pinned_uri = %{uri | host: format_address(address)}

    header_list =
      headers
      |> Map.put("host", host_header(host, port, uri.scheme))
      |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    http_options =
      [
        autoredirect: false,
        timeout: opts[:timeout] || @default_timeout,
        connect_timeout: opts[:connect_timeout] || @default_connect_timeout
      ]
      |> maybe_put_ssl(uri.scheme, host)

    url = String.to_charlist(URI.to_string(pinned_uri))

    # the 4-tuple (with content-type + body) is only valid for
    # body-carrying methods — GET/HEAD/DELETE take the 2-tuple
    request =
      case method do
        m when m in [:post, :put, :patch] ->
          {url, header_list, content_type(headers), body || ""}

        _bodyless ->
          {url, header_list}
      end

    with {:ok, req_id} <-
           :httpc.request(method, request, http_options, sync: false, stream: :self) do
      collect(req_id, opts[:max_body_bytes] || @default_max_body_bytes)
    end
  end

  # :httpc streams ONLY 2xx (200/206 — see httpc_response.erl's result/2);
  # every other status arrives as the complete result message, so the
  # status is always recoverable: streamed ⇒ 2xx.
  defp collect(req_id, max_body) do
    receive do
      {:http, {^req_id, :stream_start, headers}} ->
        stream_body(req_id, headers, 200, "", max_body)

      {:http, {^req_id, {{_version, status, _phrase}, headers, body}}} ->
        {:ok, %{status: status, headers: normalize_headers(headers), body: safe_body(body)}}

      {:http, {^req_id, {:error, reason}}} ->
        {:error, reason}
    after
      30_000 -> {:error, :response_timeout}
    end
  end

  defp stream_body(req_id, headers, status, acc, max_body) do
    receive do
      {:http, {^req_id, :stream, chunk}} ->
        acc = acc <> chunk

        if byte_size(acc) >= max_body do
          # bounded: keep the first max_body bytes, abandon the rest
          :httpc.cancel_request(req_id)

          {:ok,
           %{
             status: status,
             headers: normalize_headers(headers),
             body: binary_part(acc, 0, max_body)
           }}
        else
          stream_body(req_id, headers, status, acc, max_body)
        end

      {:http, {^req_id, :stream_end, _headers}} ->
        {:ok, %{status: status, headers: normalize_headers(headers), body: acc}}
    after
      30_000 ->
        :httpc.cancel_request(req_id)
        {:error, :response_timeout}
    end
  end

  defp default_port("https"), do: 443
  defp default_port(_http), do: 80

  defp host_header(host, 443, "https"), do: host
  defp host_header(host, 80, "http"), do: host
  defp host_header(host, port, _), do: "#{host}:#{port}"

  # the pinned URL carries the validated IP; TLS still names the ORIGINAL
  # host (SNI + RFC 6125 hostname check against it)
  defp ssl_options("https", host) do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  defp ssl_options(_http, _host), do: []

  # an empty :ssl option on a plain-http request is rejected by :httpc —
  # only attach it for https
  defp maybe_put_ssl(options, "https", host),
    do: Keyword.put(options, :ssl, ssl_options("https", host))

  defp maybe_put_ssl(options, _http, _host), do: options

  defp content_type(headers) do
    case Map.get(headers, "content-type") do
      ct when is_binary(ct) -> String.to_charlist(ct)
      _ -> ~c"application/json"
    end
  end

  defp format_address(address) do
    formatted = address |> :inet.ntoa() |> to_string()
    if String.contains?(formatted, ":"), do: "[#{formatted}]", else: formatted
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end

  defp safe_body(body) when is_binary(body), do: body
  defp safe_body(body) when is_list(body), do: IO.iodata_to_binary(body)
  defp safe_body(_), do: nil
end
