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
  (the remainder is simply not read; the connection closes). Timeouts:
  connect 5s, receive 15s (the Oban job timeout is the outer bound).

  `AshHooks.Http.Httpc` remains available as an alternative adapter
  (swap via the worker's `:http` opt) — its non-2xx streaming limitation
  is why this module exists as the default.
  """

  @behaviour AshHooks.Http

  alias AshHooks.Http.Target

  @recv_slice 8 * 1024
  @default_max_header_bytes 32 * 1024
  @default_max_body_bytes 65_536
  @default_connect_timeout 5_000
  @default_timeout 15_000

  @impl true
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

    with {:ok, socket} <- connect(target, opts) do
      try do
        case send_all(socket, IO.iodata_to_binary(request)) do
          :ok -> read_response(socket, opts)
          {:error, reason} -> {:error, reason}
        end
      after
        close(socket)
      end
    end
  end

  defp request_path(%{path: nil, query: nil}), do: "/"
  defp request_path(%{path: nil, query: q}), do: "/?" <> q
  defp request_path(%{path: p, query: nil}), do: p
  defp request_path(%{path: p, query: q}), do: p <> "?" <> q

  defp connect(%{uri: %URI{scheme: "https"}} = target, opts) do
    :ssl.connect(
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
    )
  end

  defp connect(target, opts) do
    :gen_tcp.connect(
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
    )
  end

  defp send_all(socket, data) do
    mod = if is_port(socket), do: :gen_tcp, else: :ssl

    case mod.send(socket, data) do
      :ok -> :ok
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp close(socket) do
    if is_port(socket), do: :gen_tcp.close(socket), else: :ssl.close(socket)
  end

  defp recv(socket, timeout) do
    if is_port(socket), do: :gen_tcp.recv(socket, 0, timeout), else: :ssl.recv(socket, 0, timeout)
  end

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

  # check the bound BEFORE the terminator match — a hostile header block
  # must be refused even when its terminator arrives in the same pull
  defp head_step(acc, max) when byte_size(acc) > max, do: {:error, :header_block_too_large}

  defp head_step(acc, _max) do
    case :binary.match(acc, "\r\n\r\n") do
      {index, _} -> split_head(acc, index + 4)
      :nomatch -> {:more, acc}
    end
  end

  defp split_head(acc, head_len) do
    {:ok, binary_part(acc, 0, head_len), binary_part(acc, head_len, byte_size(acc) - head_len)}
  end

  defp parse_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n", trim: false)

    with [_, status_binary, _reason] <- String.split(status_line, " ", parts: 3),
         {status, ""} <- Integer.parse(status_binary) do
      {:ok, {status, parse_header_lines(header_lines)}}
    else
      _malformed -> {:error, :malformed_status_line}
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
        {length, ""} = Integer.parse(length_binary)
        read_sized(socket, status, headers, acc, length, max, timeout)

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
        {:ok, %{status: status, headers: headers, body: acc}}

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
        {buffer, acc} = take_chunk(socket, rest, acc, size, max, timeout)
        chunked_loop(socket, buffer, acc, max, timeout)

      :need_more ->
        case recv(socket, timeout) do
          {:ok, chunk} -> chunked_loop(socket, buffer <> chunk, acc, max, timeout)
          {:error, :closed} -> {:ok, acc}
          {:error, reason} -> {:error, reason}
        end

      :malformed ->
        {:ok, acc}
    end
  end

  defp next_chunk_size(buffer) do
    case :binary.match(buffer, "\r\n") do
      :nomatch ->
        :need_more

      {index, _} ->
        case buffer |> binary_part(0, index) |> Integer.parse(16) do
          {size, _rest} ->
            {:ok, size, binary_part(buffer, index + 2, byte_size(buffer) - index - 2)}

          :error ->
            :malformed
        end
    end
  end

  defp take_chunk(socket, buffer, acc, size, max, timeout) do
    needed = size + 2

    if byte_size(buffer) < needed do
      case recv(socket, timeout) do
        {:ok, chunk} -> take_chunk(socket, buffer <> chunk, acc, size, max, timeout)
        {:error, _} -> {"", acc}
      end
    else
      chunk = binary_part(buffer, 0, min(size, max - byte_size(acc)))
      # carry the POST-chunk remainder forward — the next size line (and
      # possibly more chunks) may already be buffered
      rest = binary_part(buffer, needed, byte_size(buffer) - needed)
      {rest, acc <> chunk}
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
