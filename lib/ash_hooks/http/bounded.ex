defmodule AshHooks.Http.Bounded do
  @moduledoc """
  A minimal, memory-bounded HTTP/1.1 client over `:gen_tcp`/`:ssl` — the
  DEFAULT adapter (derisk-2): EVERY read is capped, under all framings,
  so no response — 2xx or not — can balloon a delivery worker's memory.

  What it speaks: exactly what the delivery runtime sends — `POST` (or
  the standard verbs), our own headers, `Connection: close`, no redirects,
  no keep-alive, no 100-continue. The connection goes to the PINNED,
  validated address (`AshHooks.Http.Target`); TLS names the original host.

  Bounds (all opt-overridable): header block ≤ `:max_header_bytes`
  (32 KiB), body ≤ `:max_body_bytes` (64 KiB) — Content-Length, chunked,
  and read-to-close framings alike; a chunked body is CUT at the bound
  (the remainder is simply not read; the connection closes). A body that
  ends EARLY — the server closes before the framing completes — is
  `{:error, :truncated_body}` under Content-Length and chunked framings
  alike (read-to-close has no early end by definition). Timeouts:
  connect 5s, receive 15s (the Oban job timeout is the outer bound).

  `AshHooks.Http.Httpc` remains available as an alternative adapter
  (swap via the worker's `:http` opt) — its non-2xx streaming limitation
  is why this module exists as the default.
  """

  @behaviour AshHooks.Http

  alias AshHooks.Http.CertSan
  alias AshHooks.Http.Target

  @recv_slice 8 * 1024
  @default_max_header_bytes 32 * 1024
  @default_max_body_bytes 65_536
  @default_connect_timeout 5_000
  @default_timeout 15_000

  @impl true
  @spec request(atom(), String.t(), map(), binary() | nil, keyword()) ::
          {:ok, %{status: integer(), headers: list(), body: binary() | nil}}
          | {:error, term()}
  def request(method, url, headers, body, opts \\ []) do
    method = if is_binary(method), do: String.to_atom(method), else: method

    with {:ok, target} <- Target.resolve(url, opts) do
      send_request(method, target, Map.new(headers), body || "", opts)
    end
  end

  defp send_request(method, target, headers, body, opts) do
    request_line =
      "#{method |> Atom.to_string() |> String.upcase()} " <>
        "#{request_path(target.uri)} HTTP/1.1\r\n"

    header_lines =
      [
        {"host", Target.host_header(target.host, target.port, target.uri.scheme)},
        {"connection", "close"},
        {"content-length", Integer.to_string(byte_size(body))}
      ]
      |> Kernel.++(Map.to_list(headers))
      |> Enum.map(fn {name, value} -> "#{name}: #{value}\r\n" end)

    request = [request_line, header_lines, "\r\n", body]

    with {:ok, transport} <- connect(target, opts) do
      try do
        case send_all(transport, IO.iodata_to_binary(request)) do
          :ok -> read_response(transport, opts)
          {:error, reason} -> {:error, reason}
        end
      after
        close(transport)
      end
    end
  end

  # For literal-IP https destinations TLS has no NAME to check — require
  # the peer cert to carry the IP in its iPAddress SAN (chain validation
  # alone lets ANY publicly-trusted cert authenticate the peer;
  # cross-vendor finding). No-op for named hosts (the RFC 6125 hostname
  # check covers those). SAN matching lives in `AshHooks.Http.CertSan`
  # (fixture-tested): found broken by dialyzer 2026-08-22 —
  # `pkix_decode_cert/2` returns the cert record directly, so the old
  # `{:ok, cert} <-` chain never reached the matcher and EVERY literal-IP
  # https endpoint was rejected fail-closed.
  @spec verify_ip_san(:ssl.sslsocket(), map()) :: :ok | {:error, :cert_ip_mismatch}
  defp verify_ip_san(socket, %{host: host, address: address}) do
    if Target.ip_literal?(host) do
      with {:ok, der} <- :ssl.peercert(socket),
           true <- CertSan.ip_san_match?(der, address) do
        :ok
      else
        _no_ip_san -> {:error, :cert_ip_mismatch}
      end
    else
      :ok
    end
  end

  defp request_path(%{path: nil, query: nil}), do: "/"
  defp request_path(%{path: nil, query: q}), do: "/?" <> q
  defp request_path(%{path: p, query: nil}), do: p
  defp request_path(%{path: p, query: q}), do: p <> "?" <> q

  defp connect(%{uri: %URI{scheme: "https"}} = target, opts) do
    case :ssl.connect(
           target.address,
           target.port,
           [
             mode: :binary,
             active: false,
             packet: :raw,
             # ONE passive recv must not pull a hostile body whole — this caps
             # the pull; the read loops stop at their bounds
             buffer: @recv_slice
           ] ++ Target.ssl_options(target.host),
           opts[:connect_timeout] || @default_connect_timeout
         ) do
      {:ok, socket} ->
        # IP-SAN verification runs HERE — the ssl socket must reach
        # :ssl.peercert/1 as a direct opaque binding (see verify_ip_san)
        case verify_ip_san(socket, target) do
          :ok ->
            {:ok, {:ssl, socket}}

          {:error, _reason} = error ->
            :ssl.close(socket)
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(target, opts) do
    case :gen_tcp.connect(
           target.address,
           target.port,
           [
             mode: :binary,
             active: false,
             packet: :raw,
             # ONE passive recv must not pull a hostile body whole — this caps
             # the pull; the read loops stop at their bounds
             buffer: @recv_slice
           ],
           opts[:connect_timeout] || @default_connect_timeout
         ) do
      {:ok, socket} -> {:ok, {:tcp, socket}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp send_all({:tcp, socket}, data), do: send_all(:gen_tcp, socket, data)
  defp send_all({:ssl, socket}, data), do: send_all(:ssl, socket, data)

  defp send_all(mod, socket, data) do
    case mod.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp close({:tcp, socket}), do: :gen_tcp.close(socket)
  defp close({:ssl, socket}), do: :ssl.close(socket)

  defp recv({:tcp, socket}, timeout), do: :gen_tcp.recv(socket, 0, timeout)
  defp recv({:ssl, socket}, timeout), do: :ssl.recv(socket, 0, timeout)

  # ── response reading: header block, then body by framing ──────────

  defp read_response(socket, opts) do
    timeout = opts[:timeout] || @default_timeout

    with {:ok, head, rest} <-
           read_head(socket, "", 0, opts[:max_header_bytes] || @default_max_header_bytes, timeout),
         {:ok, {status, headers}} <- parse_head(head) do
      read_body(
        socket,
        status,
        headers,
        rest,
        opts[:max_body_bytes] || @default_max_body_bytes,
        timeout
      )
    end
  end

  defp read_head(_socket, acc, _size, max, _timeout) when byte_size(acc) > max,
    do: {:error, :header_block_too_large}

  defp read_head(socket, acc, _size, max, timeout) do
    case recv(socket, timeout) do
      {:ok, chunk} ->
        case head_step(acc <> chunk, max) do
          {:more, acc} -> read_head(socket, acc, byte_size(acc), max, timeout)
          done -> done
        end

      {:error, :closed} ->
        case :binary.match(acc, "\r\n\r\n") do
          {index, _} -> split_head(acc, index + 4)
          :nomatch -> {:error, :truncated_response}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # terminator FIRST: same-pull body bytes must not count against the
  # header bound (a legit header + trailing body in one slice); the bound
  # refuses only a header block that keeps GROWING without a terminator
  defp head_step(acc, max) do
    case :binary.match(acc, "\r\n\r\n") do
      {index, _} when index + 4 <= max -> split_head(acc, index + 4)
      {_over_max, _} -> {:error, :header_block_too_large}
      :nomatch when byte_size(acc) > max -> {:error, :header_block_too_large}
      :nomatch -> {:more, acc}
    end
  end

  defp split_head(acc, head_len) do
    {:ok, binary_part(acc, 0, head_len), binary_part(acc, head_len, byte_size(acc) - head_len)}
  end

  defp parse_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n", trim: false)

    with {:ok, status_binary} <- status_binary(status_line),
         {status, ""} <- Integer.parse(status_binary) do
      {:ok, {status, parse_header_lines(header_lines)}}
    else
      _malformed -> {:error, :malformed_status_line}
    end
  end

  # embedded/minimal servers may omit the reason phrase ("HTTP/1.1 200")
  defp status_binary(status_line) do
    case String.split(status_line, " ", parts: 3) do
      [_, status, _reason] -> {:ok, status}
      [_, status] -> {:ok, status}
      _ -> :error
    end
  end

  defp parse_header_lines(lines) do
    lines
    |> Enum.take_while(&(&1 not in ["", "\r\n"]))
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{String.downcase(String.trim(name)), String.trim(value)}]
        _other -> []
      end
    end)
  end

  defp read_body(socket, status, headers, acc, max, timeout) do
    cond do
      status in [204, 304] ->
        {:ok, %{status: status, headers: headers, body: acc}}

      chunked?(headers) ->
        read_chunked(socket, status, headers, acc, "", max, timeout)

      framed_length = List.keyfind(headers, "content-length", 0) ->
        {_name, length_binary} = framed_length

        case Integer.parse(length_binary) do
          {length, ""} when length >= 0 ->
            # the body bytes that arrived WITH the header block count
            # against the declared length — otherwise termination waits
            # for a close the server may never send (cross-vendor probe)
            read_sized(
              socket,
              status,
              headers,
              acc,
              max(0, length - byte_size(acc)),
              max,
              timeout
            )

          _malformed ->
            {:error, :malformed_content_length}
        end

      true ->
        read_to_close(socket, status, headers, acc, max, timeout)
    end
  end

  defp chunked?(headers) do
    case List.keyfind(headers, "transfer-encoding", 0) do
      {_, value} -> String.contains?(String.downcase(value), "chunked")
      nil -> false
    end
  end

  defp read_sized(_socket, status, headers, acc, remaining, max, _timeout)
       when byte_size(acc) >= max or remaining <= 0 do
    # bounded: never read past the cap — the rest of the body is simply
    # not fetched (Connection: close disposes of it)
    {:ok,
     %{status: status, headers: headers, body: binary_part(acc, 0, min(byte_size(acc), max))}}
  end

  defp read_sized(socket, status, headers, acc, remaining, max, timeout) do
    case recv(socket, timeout) do
      {:ok, chunk} ->
        acc = acc <> chunk
        read_sized(socket, status, headers, acc, remaining - byte_size(chunk), max, timeout)

      {:error, :closed} ->
        # a Content-Length-framed body that ends early is a truncated
        # response — the driver must retry, never mark 2xx succeeded on
        # partial bytes (cross-vendor finding)
        {:error, :truncated_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_chunked(socket, status, headers, buffer, acc, max, timeout) do
    with {:ok, body} <- chunked_loop(socket, buffer, acc, max, timeout) do
      {:ok, %{status: status, headers: headers, body: body}}
    end
  end

  defp chunked_loop(_socket, _buffer, acc, max, _timeout) when byte_size(acc) >= max,
    do: {:ok, binary_part(acc, 0, max)}

  defp chunked_loop(socket, buffer, acc, max, timeout) do
    case next_chunk_size(buffer) do
      {:ok, 0, _rest} ->
        {:ok, acc}

      {:ok, size, rest} ->
        case take_chunk(socket, rest, acc, size, max, timeout) do
          {:ok, {buffer, acc}} -> chunked_loop(socket, buffer, acc, max, timeout)
          {:error, reason} -> {:error, reason}
        end

      :need_more ->
        chunked_need_more(socket, buffer, acc, max, timeout)

      :malformed ->
        {:error, :malformed_chunked}
    end
  end

  defp chunked_need_more(socket, buffer, acc, max, timeout) do
    case recv(socket, timeout) do
      {:ok, chunk} ->
        chunked_loop(socket, buffer <> chunk, acc, max, timeout)

      # a close before the terminal 0-chunk is the chunked twin of a
      # short Content-Length body — truncated, never a partial ok
      {:error, :closed} ->
        {:error, :truncated_body}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_chunk_size(buffer) do
    case :binary.match(buffer, "\r\n") do
      :nomatch ->
        :need_more

      {index, _} ->
        case buffer |> binary_part(0, index) |> Integer.parse(16) do
          # a chunk-size line is a hex length — negative parses are
          # hostile (Integer.parse accepts "-1"); they must classify as
          # malformed, never reach binary_part and raise
          {size, _rest} when size >= 0 ->
            {:ok, size, binary_part(buffer, index + 2, byte_size(buffer) - index - 2)}

          {_negative, _rest} ->
            :malformed

          :error ->
            :malformed
        end
    end
  end

  # The declared chunk size is ATTACKER-CONTROLLED — never buffer toward
  # it (a 1TB declaration must not allocate). Retain at most the
  # remaining ALLOWANCE of the chunk's bytes, consume the rest slice-wise
  # (cross-vendor live probe: both peers). Recv pulls are already capped
  # by the socket's buffer option, so the buffered excess is one slice.
  defp take_chunk(socket, buffer, acc, size, max, timeout) do
    allowance = max(max - byte_size(acc), 0)
    keep = min(size, allowance)
    needed = size + 2

    if byte_size(buffer) < needed do
      case recv(socket, timeout) do
        {:ok, chunk} -> take_chunk(socket, buffer <> chunk, acc, size, max, timeout)
        # a close mid-chunk is truncation — never silently swallow the
        # error and return the partial accumulator as a complete body
        {:error, :closed} -> {:error, :truncated_body}
        {:error, reason} -> {:error, reason}
      end
    else
      # carry the POST-chunk remainder forward — the next size line (and
      # possibly more chunks) may already be buffered
      rest = binary_part(buffer, needed, byte_size(buffer) - needed)
      {:ok, {rest, acc <> binary_part(buffer, 0, keep)}}
    end
  end

  defp read_to_close(socket, status, headers, acc, max, timeout) do
    if byte_size(acc) >= max do
      {:ok, %{status: status, headers: headers, body: binary_part(acc, 0, max)}}
    else
      case recv(socket, timeout) do
        {:ok, chunk} -> read_to_close(socket, status, headers, acc <> chunk, max, timeout)
        {:error, :closed} -> {:ok, %{status: status, headers: headers, body: acc}}
        {:error, reason} -> {:error, reason}
      end
    end
  end
end
