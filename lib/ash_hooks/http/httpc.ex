defmodule AshHooks.Http.Httpc do
  @moduledoc """
  An `AshHooks.Http` adapter built on OTP's `:httpc`.

  The adapter resolves and validates the destination, pins the connection
  address, and preserves the original hostname for TLS certificate verification,
  SNI, and the Host header. Redirects are returned without following them.
  TLS uses the OTP CA store unless `cacerts: der_list` supplies a private CA
  bundle. The operation deadline covers DNS, connection, send, and response
  collection; connection also has a separate, shorter ceiling.

  Response retention is capped by `max_body_bytes` (64 KiB by default).
  OTP streams 200 and 206 responses, so this adapter cancels collection at
  that limit. Other statuses are buffered inside `:httpc` before the adapter
  can truncate them. Use the default `AshHooks.Http.Bounded` adapter when the
  allocation of an untrusted error response must also be bounded. OTP's
  streaming interface does not distinguish 206 from 200; both are reported
  as 200 by this adapter and classified as successful delivery.

  HTTPS URLs with literal IP hosts return
  `{:error, :ip_literal_https_needs_bounded}`. Use `AshHooks.Http.Bounded` for
  those endpoints: it can inspect the socket certificate's IP subject
  alternative name as well as validate its certificate chain.
  """

  @behaviour AshHooks.Http

  alias AshHooks.Http.Headers
  alias AshHooks.Http.Target

  @default_timeout 15_000
  @default_connect_timeout 5_000
  @default_max_body_bytes 65_536

  @methods %{
    "delete" => :delete,
    "get" => :get,
    "head" => :head,
    "options" => :options,
    "patch" => :patch,
    "post" => :post,
    "put" => :put,
    "trace" => :trace
  }

  @impl true
  @spec request(atom(), String.t(), map(), binary() | nil, keyword()) ::
          {:ok, %{status: integer(), headers: list(), body: binary() | nil}}
          | {:error, term()}
  def request(method, url, headers, body, opts \\ []) do
    deadline = System.monotonic_time(:millisecond) + (opts[:timeout] || @default_timeout)

    # shared pinning substrate (also the test seam — the SSRF obligation
    # lives in the driver's send-time check; adapter resolution is
    # defense-in-depth)
    with {:ok, method} <- normalize_method(method),
         {:ok, headers} <- Headers.validate(headers) do
      case Target.resolve(url, Keyword.put(opts, :deadline, deadline)) do
        {:ok, target} ->
          pinned_request(method, target, headers, body, opts, deadline)

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp normalize_method(method) when is_atom(method) do
    if method in Map.values(@methods), do: {:ok, method}, else: {:error, :unsupported_method}
  end

  defp normalize_method(method) when is_binary(method) do
    if String.valid?(method) do
      Map.fetch(@methods, String.downcase(method))
      |> case do
        {:ok, normalized} -> {:ok, normalized}
        :error -> {:error, :unsupported_method}
      end
    else
      {:error, :unsupported_method}
    end
  end

  defp normalize_method(_method), do: {:error, :unsupported_method}

  defp pinned_request(method, target, headers, body, opts, deadline) do
    # A literal-IP https destination FAILS CLOSED on this adapter: without
    # a hostname there is no RFC 6125 check, and :httpc never hands us the
    # socket so the iPAddress-SAN floor (cert_san.ex — Bounded enforces it)
    # cannot run. Chain validation alone would let ANY cert chaining to
    # the trust store authenticate the endpoint IP. Use Bounded (the
    # default adapter) for literal-IP https endpoints.
    if target.uri.scheme == "https" and Target.ip_literal?(target.host) do
      {:error, :ip_literal_https_needs_bounded}
    else
      do_pinned_request(method, target, headers, body, opts, deadline)
    end
  end

  defp do_pinned_request(method, target, headers, body, opts, deadline) do
    host = target.host
    pinned_uri = %{target.uri | host: format_address(target.address)}

    header_list =
      headers
      |> Map.put("host", Target.host_header(host, target.port, target.uri.scheme))
      |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

    http_options =
      [
        autoredirect: false,
        timeout: remaining_timeout(deadline),
        connect_timeout:
          min(remaining_timeout(deadline), opts[:connect_timeout] || @default_connect_timeout)
      ]
      |> maybe_put_ssl(target.uri.scheme, host, opts[:cacerts])

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
      collect(req_id, opts[:max_body_bytes] || @default_max_body_bytes, deadline)
    end
  end

  # :httpc streams ONLY 2xx (200/206 — see httpc_response.erl's result/2);
  # every other status arrives as the complete result message, so the
  # status is always recoverable: streamed ⇒ 2xx. A streamed 206 is
  # indistinguishable from a 200 in this client's streaming API and is
  # recorded as 200 (classification is unaffected — both are 2xx).
  defp collect(req_id, max_body, deadline) do
    receive do
      {:http, {^req_id, :stream_start, headers}} ->
        stream_body(req_id, headers, 200, "", max_body, deadline)

      {:http, {^req_id, {{_version, status, _phrase}, headers, body}}} ->
        # the transparent path assembles inside :httpc before delivery
        # (no earlier cut exists in the client API) — truncate OUR
        # retention at the bound; the transient allocation is the
        # documented residual. :httpc delivers its own timeout error
        # message first, so no caller-side backstop fires here.
        {:ok,
         %{
           status: status,
           headers: normalize_headers(headers),
           body: truncate(body, max_body)
         }}

      {:http, {^req_id, {:error, reason}}} ->
        {:error, reason}
    after
      remaining_timeout(deadline) ->
        :httpc.cancel_request(req_id)
        {:error, :timeout}
    end
  end

  defp stream_body(req_id, headers, status, acc, max_body, deadline) do
    receive do
      # a mid-stream transport failure is delivered this way — without
      # this clause the caller stalls to the backstop and loses the
      # reason
      {:http, {^req_id, {:error, reason}}} ->
        :httpc.cancel_request(req_id)
        {:error, reason}

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
          stream_body(req_id, headers, status, acc, max_body, deadline)
        end

      {:http, {^req_id, :stream_end, _headers}} ->
        {:ok, %{status: status, headers: normalize_headers(headers), body: acc}}
    after
      remaining_timeout(deadline) ->
        :httpc.cancel_request(req_id)
        {:error, :timeout}
    end
  end

  defp remaining_timeout(deadline),
    do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp truncate(body, max) when byte_size(body) > max, do: binary_part(body, 0, max)
  defp truncate(body, _max), do: body

  # the pinned URL carries the validated IP; TLS still names the ORIGINAL
  # host (SNI + RFC 6125 hostname check against it). Same :cacerts seam as
  # Bounded — a pinned private-CA bundle survives an adapter swap. Named
  # hosts only: pinned_request refuses literal-IP https before this runs.
  defp ssl_options(host, cacerts) do
    [
      verify: :verify_peer,
      cacerts: cacerts || :public_key.cacerts_get(),
      depth: 3,
      server_name_indication: String.to_charlist(host),
      customize_hostname_check: [
        match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
      ]
    ]
  end

  # an empty :ssl option on a plain-http request is rejected by :httpc —
  # only attach it for https (named hosts only; literal-IP https never
  # reaches here — pinned_request refuses it first)
  defp maybe_put_ssl(options, "https", host, cacerts),
    do: Keyword.put(options, :ssl, ssl_options(host, cacerts))

  defp maybe_put_ssl(options, _http, _host, _cacerts), do: options

  defp content_type(headers) do
    case Map.get(headers, "content-type") do
      ct when is_binary(ct) -> String.to_charlist(ct)
      _ -> ~c"application/json"
    end
  end

  # UNbracketed: URI.to_string brackets a ":"-containing host itself —
  # pre-wrapping here produced double brackets
  defp format_address(address), do: address |> :inet.ntoa() |> to_string()

  defp normalize_headers(headers) do
    Enum.map(headers, fn {name, value} -> {to_string(name), to_string(value)} end)
  end
end
