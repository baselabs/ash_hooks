defmodule AshHooks.Http.Bounded do
  @moduledoc """
  The default `AshHooks.Http` adapter: HTTP/1.1 over `:gen_tcp` and `:ssl`,
  with bounded response collection and one operation deadline.

  Each connection carries one request with `Connection: close`. The adapter
  returns redirects without following them and consumes informational responses
  before the final response, with a default limit of eight interim responses.
  It connects to a validated, pinned IP address while retaining the original
  host for the HTTP authority, TLS SNI, and certificate verification.

  Defaults are 32 KiB for cumulative response headers, 64 KiB for the retained
  body, five seconds for connection setup, and 15 seconds for the complete
  operation. The operation deadline includes DNS, connection, send, and reads.
  Options may override those limits.

  Body limits apply to Content-Length, chunked, and read-to-close responses.
  Collection stops at the cap and closes the connection without draining the
  remainder. Before the cap is reached, an early close in a Content-Length or
  chunked response returns `{:error, :truncated_body}`. Read-to-close framing
  ends normally when the peer closes.

  TLS uses the OTP CA store unless `cacerts: der_list` supplies a private CA
  bundle through the adapter options or worker's `http_opts`. Literal HTTPS IP
  addresses must also match the certificate's IP subject alternative name.
  See `AshHooks.Http.Httpc` for the alternative adapter's buffering limitations.
  """

  @behaviour AshHooks.Http

  alias AshHooks.Http.CertSan
  alias AshHooks.Http.Headers
  alias AshHooks.Http.Target

  @recv_slice 8 * 1024
  @default_max_header_bytes 32 * 1024
  @default_max_body_bytes 65_536
  @default_connect_timeout 5_000
  @default_timeout 15_000
  @default_max_interim_responses 8

  @methods %{
    "connect" => :connect,
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

    with {:ok, method} <- normalize_method(method),
         {:ok, headers} <- Headers.validate(headers),
         {:ok, target} <- Target.resolve(url, Keyword.put(opts, :deadline, deadline)) do
      send_request(method, target, headers, body || "", opts, deadline)
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

  defp send_request(method, target, headers, body, opts, deadline) do
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

    with {:ok, transport} <- connect(target, opts, deadline) do
      try do
        # A send failure needs no arm of its own: the Erlang inet/ssl
        # drivers QUEUE sends and surface peer-death errors on the NEXT
        # socket operation (probed on macOS AND Linux, TCP and TLS, at
        # 512MB against a receive window capped to 1KB — send returns :ok
        # and the error arrives at the read). A socket that errors a send
        # errors the read faster, and the read's existing error arms carry
        # the same retry/terminal classification the caller needs.
        with :ok <- send_all(transport, IO.iodata_to_binary(request)) do
          read_response(transport, opts, deadline)
        end
      after
        close(transport)
      end
    end
  end

  # For literal-IP https destinations TLS has no NAME to check — require
  # the peer cert to carry the IP in its iPAddress SAN (chain validation
  # alone lets ANY publicly-trusted cert authenticate the peer;
  # hardening). No-op for named hosts (the RFC 6125 hostname
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

  defp connect(%{uri: %URI{scheme: "https"}} = target, opts, deadline) do
    timeout = remaining_timeout(deadline, opts[:connect_timeout] || @default_connect_timeout)

    case :ssl.connect(
           target.address,
           target.port,
           [
             mode: :binary,
             active: false,
             packet: :raw,
             # ONE passive recv must not pull a hostile body whole — this caps
             # the pull; the read loops stop at their bounds
             buffer: @recv_slice,
             send_timeout: remaining_timeout(deadline),
             send_timeout_close: true
           ] ++ Target.ssl_options(target.host, opts[:cacerts]),
           timeout
         ) do
      {:ok, socket} ->
        # IP-SAN verification runs HERE — the ssl socket must reach
        # :ssl.peercert/1 as a direct opaque binding (see verify_ip_san)
        case verify_ip_san(socket, target) do
          :ok ->
            :ok = :ssl.setopts(socket, send_timeout: remaining_timeout(deadline))
            {:ok, {:ssl, socket}}

          {:error, _reason} = error ->
            :ssl.close(socket)
            error
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(target, opts, deadline) do
    timeout = remaining_timeout(deadline, opts[:connect_timeout] || @default_connect_timeout)

    case :gen_tcp.connect(
           target.address,
           target.port,
           [
             mode: :binary,
             active: false,
             packet: :raw,
             # ONE passive recv must not pull a hostile body whole — this caps
             # the pull; the read loops stop at their bounds
             buffer: @recv_slice,
             send_timeout: remaining_timeout(deadline),
             send_timeout_close: true
           ],
           timeout
         ) do
      {:ok, socket} ->
        :ok = :inet.setopts(socket, send_timeout: remaining_timeout(deadline))
        {:ok, {:tcp, socket}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_all({:tcp, socket}, data), do: send_all(:gen_tcp, socket, data)
  defp send_all({:ssl, socket}, data), do: send_all(:ssl, socket, data)

  defp send_all(mod, socket, data), do: mod.send(socket, data)

  defp close({:tcp, socket}), do: :gen_tcp.close(socket)
  defp close({:ssl, socket}), do: :ssl.close(socket)

  defp recv({:tcp, socket}, deadline),
    do: :gen_tcp.recv(socket, 0, remaining_timeout(deadline))

  defp recv({:ssl, socket}, deadline), do: :ssl.recv(socket, 0, remaining_timeout(deadline))

  defp remaining_timeout(deadline, cap \\ :infinity) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    if cap == :infinity, do: remaining, else: min(remaining, cap)
  end

  # ── response reading: header block, then body by framing ──────────

  defp read_response(socket, opts, deadline) do
    read_final_response(
      socket,
      "",
      opts[:max_header_bytes] || @default_max_header_bytes,
      opts[:max_body_bytes] || @default_max_body_bytes,
      opts[:max_interim_responses] || @default_max_interim_responses,
      0,
      deadline
    )
  end

  defp read_final_response(socket, acc, header_bytes_left, max_body, max_interim, count, deadline) do
    with {:ok, head, rest} <- read_head(socket, acc, 0, header_bytes_left, deadline),
         {:ok, {status, headers}} <- parse_head(head) do
      cond do
        status == 101 ->
          {:error, :unsupported_protocol_switch}

        status in 100..199 and count >= max_interim ->
          {:error, :too_many_interim_responses}

        status in 100..199 ->
          read_final_response(
            socket,
            rest,
            header_bytes_left - byte_size(head),
            max_body,
            max_interim,
            count + 1,
            deadline
          )

        true ->
          read_body(socket, status, headers, rest, max_body, deadline)
      end
    end
  end

  defp read_head(socket, acc, _size, max, deadline) do
    case head_step(acc, max) do
      {:more, acc} ->
        case recv(socket, deadline) do
          {:ok, chunk} ->
            read_head(socket, acc <> chunk, byte_size(acc), max, deadline)

          {:error, :closed} ->
            # acc cannot hold a terminator here: head_step splits any complete
            # one on arrival, so a close means the head never finished
            {:error, :truncated_response}

          {:error, reason} ->
            {:error, reason}
        end

      done ->
        done
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
            # for a close the server may never send (a robustness probe)
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
        # partial bytes
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

  # a size line is a hex length — a handful of characters (the absurd
  # bound admits any legal encoding). A buffer past it with no terminator
  # is a hostile run-on: malformed, never buffered
  @max_size_line 64

  defp next_chunk_size(buffer) do
    case :binary.match(buffer, "\r\n") do
      :nomatch when byte_size(buffer) > @max_size_line ->
        :malformed

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

  # The declared chunk size is ATTACKER-CONTROLLED — NEVER buffer toward
  # it. Keep only the remaining allowance. Once that reaches the body cap,
  # return immediately; do not drain attacker-controlled excess bytes or
  # wait for their terminator.
  defp take_chunk(socket, buffer, acc, size, max, timeout) do
    allowance = max(max - byte_size(acc), 0)
    keep = min(size, allowance)

    with {:ok, kept, buffer} <- take_bytes(socket, buffer, keep, timeout) do
      finish_chunk(socket, buffer, acc <> kept, max, timeout)
    end
  end

  defp finish_chunk(_socket, buffer, body, max, _timeout) when byte_size(body) >= max,
    do: {:ok, {buffer, body}}

  defp finish_chunk(socket, buffer, body, _max, timeout) do
    with {:ok, term, buffer} <- take_bytes(socket, buffer, 2, timeout),
         :ok <- validate_chunk_terminator(term) do
      {:ok, {buffer, body}}
    end
  end

  defp validate_chunk_terminator("\r\n"), do: :ok
  defp validate_chunk_terminator(_other), do: {:error, :malformed_chunked}

  # takes exactly n bytes out of (buffer ++ socket) — bounded by n plus
  # one recv slice; used only where n is attacker-INdependent (the
  # allowance, the 2-byte terminator) or already bounded by it
  defp take_bytes(_socket, buffer, n, _timeout) when byte_size(buffer) >= n,
    do: {:ok, binary_part(buffer, 0, n), binary_part(buffer, n, byte_size(buffer) - n)}

  defp take_bytes(socket, buffer, n, timeout) do
    case recv(socket, timeout) do
      {:ok, chunk} -> take_bytes(socket, buffer <> chunk, n, timeout)
      # a close mid-chunk is truncation — never a partial ok
      {:error, :closed} -> {:error, :truncated_body}
      {:error, reason} -> {:error, reason}
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
