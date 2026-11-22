defmodule AshHooks.Http.Engine do
  @moduledoc false

  alias AshHooks.Http.{CertificatePin, CertSan, Headers, Request, Target}

  @slice 8 * 1024
  @methods ~w(CONNECT DELETE GET HEAD OPTIONS PATCH POST PUT TRACE)

  def init(opts, callback \\ nil, acc \\ nil) do
    started = now()

    %{
      started: started,
      deadline: started + Keyword.get(opts, :timeout, 15_000),
      connect_deadline: started + Keyword.get(opts, :connect_timeout, 5_000),
      idle_timeout: Keyword.get(opts, :idle_timeout, 15_000),
      last_activity: started,
      phase: :validate,
      sent: :none,
      status: nil,
      headers: [],
      completion: nil,
      reason: nil,
      address_family: nil,
      method: nil,
      dns_duration_ms: 0,
      connect_duration_ms: 0,
      tls_duration_ms: 0,
      first_byte_duration_ms: nil,
      bytes_sent: 0,
      bytes_received: 0,
      body_bytes: 0,
      body: [],
      callback: callback,
      acc: acc,
      opts: opts
    }
  end

  def request(method, url, headers, body, state) do
    protect(fn ->
      method = normalize_method(method, state)
      state = %{state | method: method}
      headers = checked(Headers.validate(headers), state)
      {target, state} = resolve(url, state)
      checked(CertificatePin.validate(state.opts[:certificate_pin], target.uri.scheme), state)

      lines =
        [
          {"host", Target.host_header(target.host, target.port, target.uri.scheme)},
          {"connection", "close"},
          {"content-length", Integer.to_string(byte_size(body || ""))}
        ] ++ Map.to_list(headers)

      bytes = [
        method,
        " ",
        Request.target(target.uri),
        " HTTP/1.1\r\n",
        Enum.map(lines, fn {name, value} -> [name, ": ", value, "\r\n"] end),
        "\r\n",
        body || ""
      ]

      exchange(target, bytes, state)
    end)
  end

  def prepared(request, state) do
    protect(fn ->
      checked(Request.validate(request), state)
      state = %{state | method: request.method}
      {target, state} = resolve(request.url, state)
      checked(CertificatePin.validate(state.opts[:certificate_pin], target.uri.scheme), state)
      exchange(target, Request.to_iodata(request), state)
    end)
  end

  defp protect(fun) do
    fun.()
  catch
    {:egress_error, reason, state} -> {:error, reason, state}
    {:egress_done, state} -> {:ok, state}
  end

  defp normalize_method(method, state) when is_atom(method),
    do: normalize_method(Atom.to_string(method), state)

  defp normalize_method(method, state) when is_binary(method) do
    normalized = String.upcase(method, :ascii)
    if normalized in @methods, do: normalized, else: fail(:unsupported_method, state)
  end

  defp normalize_method(_, state), do: fail(:unsupported_method, state)

  defp resolve(url, state) do
    state = %{state | phase: :resolve}
    started = now()
    opts = Keyword.put(state.opts, :deadline, min(state.deadline, state.connect_deadline))
    result = Target.resolve(url, opts)
    state = %{state | dns_duration_ms: now() - started}
    target = checked(result, state)
    family = if tuple_size(target.address) == 4, do: :inet, else: :inet6
    {target, %{state | address_family: family}}
  end

  defp exchange(target, bytes, state) do
    state = %{state | phase: :connect}
    started = now()

    result =
      :gen_tcp.connect(
        target.address,
        target.port,
        [
          state.address_family,
          :binary,
          active: false,
          packet: :raw,
          buffer: @slice,
          send_timeout: remaining(state),
          send_timeout_close: true
        ],
        remaining(state, state.connect_deadline)
      )

    state = %{state | connect_duration_ms: now() - started}
    socket = checked(result, state)

    try do
      {transport, state} = secure(socket, target, state)

      try do
        state = %{state | phase: :send}
        deadline!(state)
        bytes = IO.iodata_to_binary(bytes)
        # This transition is immediately before the only socket write.
        state = %{state | sent: :possible}
        checked(send_all(transport, bytes), state)
        state = %{state | bytes_sent: byte_size(bytes), phase: :head, last_activity: now()}
        read_final(transport, "", state.opts[:max_header_bytes] || 32_768, 0, state)
      after
        close(transport)
      end
    after
      :gen_tcp.close(socket)
    end
  end

  defp secure(socket, %{uri: %{scheme: "http"}}, state), do: {{:gen_tcp, socket}, state}

  defp secure(socket, target, state) do
    state = %{state | phase: :tls}
    started = now()

    result =
      :ssl.connect(
        socket,
        [mode: :binary, active: false] ++ Target.ssl_options(target.host, state.opts[:cacerts]),
        remaining(state, state.connect_deadline)
      )

    state = %{state | tls_duration_ms: now() - started}
    tls = checked(result, state)

    try do
      checked(verify_peer(tls, target, state.opts[:certificate_pin]), state)
      checked(:ssl.setopts(tls, send_timeout: remaining(state)), state)
      {{:ssl, tls}, state}
    catch
      kind, term ->
        :ssl.close(tls)
        :erlang.raise(kind, term, __STACKTRACE__)
    end
  end

  defp verify_peer(socket, target, pin) do
    if Target.ip_literal?(target.host) do
      with {:ok, der} <- :ssl.peercert(socket),
           true <- CertSan.ip_san_match?(der, target.address) do
        CertificatePin.verify(socket, pin)
      else
        _ -> {:error, :cert_ip_mismatch}
      end
    else
      CertificatePin.verify(socket, pin)
    end
  end

  defp send_all({module, socket}, bytes), do: module.send(socket, bytes)
  defp close({module, socket}), do: module.close(socket)

  defp recv({module, socket}, state) do
    deadline!(state)
    idle_deadline = state.last_activity + state.idle_timeout
    timeout = remaining(state, idle_deadline)

    case module.recv(socket, 0, timeout) do
      {:ok, bytes} ->
        state = %{
          state
          | bytes_received: state.bytes_received + byte_size(bytes),
            first_byte_duration_ms: state.first_byte_duration_ms || now() - state.started,
            last_activity: now()
        }

        {bytes, state}

      {:error, :timeout} ->
        reason = if now() >= state.deadline, do: :deadline_exceeded, else: :idle_timeout
        fail(reason, state)

      {:error, reason} ->
        fail(reason, state)
    end
  end

  defp remaining(state, cap \\ nil) do
    max(min(state.deadline, cap || state.deadline) - now(), 0)
  end

  defp deadline!(state) do
    if now() >= state.deadline, do: fail(:deadline_exceeded, state)
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp checked(:ok, _state), do: :ok
  defp checked({:ok, value}, _state), do: value
  defp checked({:error, reason}, state), do: fail(reason, state)
  defp fail(reason, state), do: throw({:egress_error, reason, state})
  defp done(state, completion), do: throw({:egress_done, %{state | completion: completion}})

  defp read_final(socket, buffer, allowance, interim, state) do
    {head, rest, state} = read_head(socket, buffer, allowance, state)
    {status, headers} = checked(parse_head(head), state)

    cond do
      status == 101 ->
        fail(:unsupported_protocol_switch, %{state | status: status})

      status in 100..199 ->
        if interim >= (state.opts[:max_interim_responses] || 8),
          do: fail(:too_many_interim_responses, state)

        read_final(socket, rest, allowance - byte_size(head), interim + 1, state)

      true ->
        state = %{state | status: status, headers: headers}

        if state.opts[:egress] && status in 300..399,
          do: fail(:redirect_refused, state)

        state = event({:status, status}, state)
        state = event({:headers, headers}, state)
        read_body(socket, rest, %{state | phase: :body})
    end
  end

  defp read_head(socket, buffer, max, state) do
    case :binary.match(buffer, "\r\n\r\n") do
      {index, _} when index + 4 <= max ->
        size = index + 4
        {binary_part(buffer, 0, size), binary_part(buffer, size, byte_size(buffer) - size), state}

      {_, _} ->
        fail(:header_block_too_large, state)

      :nomatch when byte_size(buffer) > max ->
        fail(:header_block_too_large, state)

      :nomatch ->
        {bytes, state} = receive_body(socket, state, :truncated_response)
        read_head(socket, buffer <> bytes, max, state)
    end
  end

  defp parse_head(head) do
    [status_line | lines] = String.split(head, "\r\n", trim: false)

    case String.split(status_line, " ", parts: 3) do
      [_protocol, code | _] ->
        case Integer.parse(code) do
          {status, ""} -> {:ok, {status, parse_headers(lines)}}
          _ -> {:error, :malformed_status_line}
        end

      _ ->
        {:error, :malformed_status_line}
    end
  end

  defp parse_headers(lines) do
    lines
    |> Enum.take_while(&(&1 != ""))
    |> Enum.flat_map(fn line ->
      case String.split(line, ":", parts: 2) do
        [name, value] -> [{String.downcase(String.trim(name)), String.trim(value)}]
        _ -> []
      end
    end)
  end

  defp read_body(socket, buffer, state) do
    cond do
      state.method == "HEAD" or state.status in [204, 304] ->
        done(state, :complete)

      chunked?(state.headers) ->
        chunked(socket, buffer, state)

      length = List.keyfind(state.headers, "content-length", 0) ->
        case Integer.parse(elem(length, 1)) do
          {size, ""} when size >= 0 -> sized(socket, buffer, size, state)
          _ -> fail(:malformed_content_length, state)
        end

      true ->
        to_close(socket, buffer, state)
    end
  end

  defp chunked?(headers) do
    case List.keyfind(headers, "transfer-encoding", 0) do
      {_, value} -> String.contains?(String.downcase(value), "chunked")
      nil -> false
    end
  end

  defp sized(_socket, _buffer, 0, state), do: done(state, :complete)

  defp sized(socket, "", left, state) do
    {bytes, state} = receive_body(socket, state, :truncated_body)
    sized(socket, bytes, left, state)
  end

  defp sized(socket, buffer, left, state) do
    size = min(byte_size(buffer), left)
    state = data(binary_part(buffer, 0, size), state)
    sized(socket, "", left - size, state)
  end

  defp chunked(socket, buffer, state) do
    case :binary.match(buffer, "\r\n") do
      :nomatch when byte_size(buffer) > 64 ->
        fail(:malformed_chunked, state)

      :nomatch ->
        {bytes, state} = receive_body(socket, state, :truncated_body)
        chunked(socket, buffer <> bytes, state)

      {index, _} ->
        case buffer |> binary_part(0, index) |> Integer.parse(16) do
          {0, _} ->
            done(state, :complete)

          {size, _} when size > 0 ->
            rest = binary_part(buffer, index + 2, byte_size(buffer) - index - 2)
            chunk_data(socket, rest, size, state)

          _ ->
            fail(:malformed_chunked, state)
        end
    end
  end

  defp chunk_data(socket, buffer, 0, state) do
    {ending, rest, state} = take_two(socket, buffer, state)
    if ending != "\r\n", do: fail(:malformed_chunked, state)
    chunked(socket, rest, state)
  end

  defp chunk_data(socket, "", left, state) do
    {bytes, state} = receive_body(socket, state, :truncated_body)
    chunk_data(socket, bytes, left, state)
  end

  defp chunk_data(socket, buffer, left, state) do
    size = min(left, byte_size(buffer))
    state = data(binary_part(buffer, 0, size), state)
    rest = binary_part(buffer, size, byte_size(buffer) - size)
    chunk_data(socket, rest, left - size, state)
  end

  defp take_two(_socket, <<ending::binary-size(2), rest::binary>>, state),
    do: {ending, rest, state}

  defp take_two(socket, buffer, state) do
    {bytes, state} = receive_body(socket, state, :truncated_body)
    take_two(socket, buffer <> bytes, state)
  end

  defp to_close(socket, buffer, state) do
    state = data(buffer, state)

    case read_to_close(socket, state) do
      {:ok, bytes, state} -> to_close(socket, bytes, state)
      {:closed, state} -> done(state, :complete)
    end
  end

  defp read_to_close(socket, state) do
    {bytes, state} = recv(socket, state)
    {:ok, bytes, state}
  catch
    {:egress_error, :closed, state} -> {:closed, state}
  end

  defp receive_body(socket, state, truncated) do
    recv(socket, state)
  catch
    {:egress_error, :closed, state} -> fail(truncated, state)
  end

  defp data("", state), do: state

  defp data(bytes, state) do
    max = Keyword.get(state.opts, :max_body_bytes, :infinity)
    allowance = if max == :infinity, do: byte_size(bytes), else: max - state.body_bytes

    if byte_size(bytes) > allowance and !state.opts[:capture_limit],
      do: fail(:body_too_large, state)

    bytes = binary_part(bytes, 0, min(byte_size(bytes), allowance))
    state = %{state | body_bytes: state.body_bytes + byte_size(bytes)}

    state =
      if state.callback do
        event({:data, bytes}, state)
      else
        %{state | body: [bytes | state.body]}
      end

    if state.opts[:capture_limit] && state.body_bytes >= max,
      do: done(state, :capture_limit)

    state
  end

  defp event(_event, %{callback: nil} = state), do: state

  defp event(event, state) do
    result = invoke(state.callback, event, state.acc)

    case result do
      {:cont, acc} ->
        state = %{state | acc: acc}
        deadline!(state)
        state

      {:halt, acc} ->
        done(%{state | acc: acc}, :halted)

      :callback_failed ->
        fail(:callback_failed, state)
    end
  end

  defp invoke(callback, event, acc) do
    case callback.(event, acc) do
      {action, _} = result when action in [:cont, :halt] -> result
      _ -> :callback_failed
    end
  catch
    _, _ -> :callback_failed
  end
end
