defmodule AshHooks.HttpcPreparedQualificationTest do
  use ExUnit.Case, async: false
  alias AshHooks.Http.Request

  @profile :ash_hooks_prepared_qualification

  setup_all do
    {:ok, pid} = :inets.start(:httpc, profile: @profile)
    on_exit(fn -> :inets.stop(:httpc, pid) end)
    :ok
  end

  test "OTP headers_as_is preserves the complete reversed list and escaped target at a raw receiver" do
    # This qualifies the OTP mechanism before the production adapter may export
    # send_prepared/2. Run it on every supported OTP version before enabling it.
    for {ip, host} <- [{{127, 0, 0, 1}, "127.0.0.1"}, {{0, 0, 0, 0, 0, 0, 0, 1}, "[::1]"}],
        suffix <- ["", "/escaped%2Fpath?x=%2f&space=%20"] do
      family = if tuple_size(ip) == 8, do: :inet6, else: :inet
      {:ok, listener} = :gen_tcp.listen(0, [family, :binary, active: false, ip: ip, reuseaddr: true])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, port} = :inet.port(listener)
      url = "http://#{host}:#{port}#{suffix}"
      {:ok, request} = Request.new(:post, url, %{"x-first" => "first", "x-last" => "last"}, "雪")
      signature = :crypto.mac(:hmac, :sha256, "receiver-key", serialize(request)) |> Base.encode64()
      signed = %{request | headers: request.headers ++ [{"signature", signature}]}
      receiver = Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 5_000)
        try do
          bytes = read_request(socket, "")
          :ok = :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
          bytes
        after
          :gen_tcp.close(socket)
        end
      end)
      headers = signed.headers |> Enum.reverse() |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)
      http_options = [autoredirect: false, timeout: 5_000, connect_timeout: 2_000]
      options = [headers_as_is: true, body_format: :binary]
      assert {:ok, {{_, 204, _}, _, _}} = :httpc.request(:post,
        {String.to_charlist(url), headers, ~c"application/json", signed.body}, http_options, options, @profile)
      received = Task.await(receiver)
      assert received == serialize(signed)
      [head, body] = :binary.split(received, "\r\n\r\n")
      lines = String.split(head, "\r\n")
      [signature_line] = Enum.filter(lines, &String.starts_with?(&1, "signature: "))
      mac = String.replace_prefix(signature_line, "signature: ", "") |> Base.decode64!()
      original = Enum.reject(lines, &String.starts_with?(&1, "signature: ")) |> Enum.join("\r\n")
      expected = :crypto.mac(:hmac, :sha256, "receiver-key", original <> "\r\n\r\n" <> body)
      assert :crypto.hash_equals(mac, expected)
    end
  end

  defp serialize(request) do
    IO.iodata_to_binary([request.method, " ", request.target, " HTTP/1.1\r\n",
      Enum.map(request.headers, fn {name, value} -> [name, ": ", value, "\r\n"] end), "\r\n", request.body])
  end

  defp read_request(socket, bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [head, body] ->
        [_, length] = Regex.run(~r/\r\ncontent-length: (\d+)/i, head)
        if byte_size(body) == String.to_integer(length), do: bytes, else: read_more(socket, bytes)
      _ -> read_more(socket, bytes)
    end
  end

  defp read_more(socket, bytes) do
    {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
    read_request(socket, bytes <> more)
  end
end
