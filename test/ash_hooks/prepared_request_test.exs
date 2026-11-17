defmodule AshHooks.PreparedRequestTest do
  use ExUnit.Case, async: false
  alias AshHooks.Http.{Bounded, Headers, Httpc, Request}

  test "ordered validation preserves case and order and refuses duplicate or malformed lines" do
    lines = [{"X-Z", "last"}, {"X-A", "first"}]
    assert {:ok, ^lines} = Headers.validate_ordered(lines)
    assert {:error, :duplicate_header} = Headers.validate_ordered(lines ++ [{"x-z", "again"}])
    for lines <- [nil, %{}, [nil], [{"bad name", "x"}], [{"x", "\r\n"}], [{:atom, "x"}], [{"x", "y"} | :bad]] do
      assert {:error, _} = Headers.validate_ordered(lines)
    end
  end

  test "prepared authority and target cover default ports, empty paths, escapes and IPv6" do
    for {url, authority, target} <- [
      {"https://EXAMPLE.com", "example.com", "/"},
      {"http://example.com:80?x=%2f&y=%20", "example.com", "/?x=%2f&y=%20"},
      {"https://[2001:db8::1]:444/a%2Fb?q=%252f", "[2001:db8::1]:444", "/a%2Fb?q=%252f"},
      {"http://[::1]", "[::1]", "/"}
    ] do
      assert {:ok, request} = Request.new(:post, url, %{}, "雪")
      assert request.target == target
      assert request.method == "POST"
      assert {"host", authority} in request.headers
      assert {"content-length", "3"} in request.headers
      assert {"content-type", "application/json"} in request.headers
      assert :ok = Request.validate(request)
      refute inspect(request) =~ "雪"
    end
  end

  test "invalid prepared framing fails before destination lookup" do
    {:ok, request} = Request.new(:post, "http://127.0.0.1", %{}, "bytes")
    for change <- [
      %{method: "GARBAGE"}, %{body: nil}, %{target: "/changed"}, %{url: "ftp://example.com"}, %{url: nil},
      %{headers: List.keyreplace(request.headers, "host", 0, {"host", "other"})},
      %{headers: List.keyreplace(request.headers, "content-length", 0, {"content-length", "4"})},
      %{headers: List.keydelete(request.headers, "connection", 0)},
      %{headers: request.headers ++ [{"HOST", "127.0.0.1"}]}
    ] do
      assert {:error, :invalid_prepared_request} = Bounded.send_prepared(struct(request, change), [])
    end
    for {method, url, headers, body} <- [
      {:bogus, "http://example.com", %{}, ""}, {:post, "ftp://example.com", %{}, ""},
      {:post, "http://example.com/a b", %{}, ""}, {:post, "http://example.com", [], ""},
      {:post, "http://example.com", %{"host" => "evil"}, ""}, {:post, nil, %{}, ""}
    ] do
      assert {:error, _} = Request.new(method, url, headers, body)
    end
  end

  test "Bounded receiver verifies the method, escaped target, every header and UTF-8 body" do
    for {ip, authority} <- [{{127, 0, 0, 1}, "127.0.0.1"}, {{0, 0, 0, 0, 0, 0, 0, 1}, "[::1]"}],
        suffix <- ["", "/a%2Fb?x=%2F&space=%20"] do
      {listener, port} = listen(ip)
      on_exit(fn -> :gen_tcp.close(listener) end)
      url = "http://#{authority}:#{port}#{suffix}"
      {:ok, request} = Request.new(:post, url, %{"content-type" => "application/json", "x-before" => "雪"}, "雪")
      signature = :crypto.mac(:hmac, :sha256, "receiver-owned-test-key", serialize(request)) |> Base.encode64()
      signed = %{request | headers: request.headers ++ [{"signature", signature}]}
      receiver = Task.async(fn -> receive_request(listener) end)
      assert {:ok, %{status: 204}} = Bounded.send_prepared(signed, validate_destination: false)
      bytes = Task.await(receiver)
      assert bytes == serialize(signed)
      [head, body] = :binary.split(bytes, "\r\n\r\n")
      lines = String.split(head, "\r\n")
      [signature_line] = Enum.filter(lines, &String.starts_with?(&1, "signature: "))
      received_signature = String.replace_prefix(signature_line, "signature: ", "") |> Base.decode64!()
      original = Enum.reject(lines, &String.starts_with?(&1, "signature: ")) |> Enum.join("\r\n")
      expected = :crypto.mac(:hmac, :sha256, "receiver-owned-test-key", original <> "\r\n\r\n" <> body)
      assert :crypto.hash_equals(expected, received_signature)
    end
  end

  test "with options off prepared Bounded bytes equal legacy request/5 bytes" do
    {listener, port} = listen({127, 0, 0, 1})
    on_exit(fn -> :gen_tcp.close(listener) end)
    url = "http://127.0.0.1:#{port}/hook?x=%2F"
    headers = %{"content-type" => "application/json", "webhook-id" => "event-1", "x-custom" => "value"}
    receiver = Task.async(fn -> [receive_request(listener), receive_request(listener)] end)
    assert {:ok, _} = Bounded.request(:post, url, headers, "雪", validate_destination: false)
    {:ok, request} = Request.new(:post, url, headers, "雪")
    assert {:ok, _} = Bounded.send_prepared(request, validate_destination: false)
    assert [legacy, prepared] = Task.await(receiver)
    assert legacy == prepared
  end

  test "Bounded preserves a host signature at the default HTTP and HTTPS ports" do
    [{:Certificate, ca_der, :not_encrypted}] =
      :public_key.pem_decode(File.read!("test/fixtures/tls/local-ca.pem"))

    for {scheme, port, protocol} <- [{"http", 80, :gen_tcp}, {"https", 443, :ssl}] do
      options = [:binary, active: false, ip: {127, 0, 0, 1}, reuseaddr: true]
      options = if protocol == :ssl,
        do: options ++ [certfile: ~c"test/fixtures/tls/server-both-san.pem", keyfile: ~c"test/fixtures/tls/server.key"],
        else: options
      {:ok, listener} = protocol.listen(port, options)
      on_exit(fn -> protocol.close(listener) end)
      {:ok, request} = Request.new(:post, "#{scheme}://127.0.0.1?x=%2F", %{}, "雪")
      signature = :crypto.mac(:hmac, :sha256, "receiver-owned-test-key", serialize(request)) |> Base.encode64()
      signed = %{request | headers: request.headers ++ [{"signature", signature}]}
      receiver = Task.async(fn ->
        socket = if protocol == :ssl do
          {:ok, socket} = :ssl.transport_accept(listener, 5_000)
          {:ok, socket} = :ssl.handshake(socket, 5_000)
          socket
        else
          {:ok, socket} = :gen_tcp.accept(listener, 5_000)
          socket
        end
        try do
          bytes = read_request(socket, "", protocol)
          :ok = protocol.send(socket, "HTTP/1.1 204 No Content\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
          bytes
        after
          protocol.close(socket)
        end
      end)
      assert {:ok, %{status: 204}} = Bounded.send_prepared(signed,
        validate_destination: false, cacerts: [ca_der])
      bytes = Task.await(receiver)
      assert bytes == serialize(signed)
      assert {"host", "127.0.0.1"} in request.headers
      [head, body] = :binary.split(bytes, "\r\n\r\n")
      lines = String.split(head, "\r\n")
      original = Enum.reject(lines, &String.starts_with?(&1, "signature: ")) |> Enum.join("\r\n")
      [received] = for "signature: " <> value <- lines, do: Base.decode64!(value)
      assert :crypto.hash_equals(received,
        :crypto.mac(:hmac, :sha256, "receiver-owned-test-key", original <> "\r\n\r\n" <> body))
    end
  end

  test "Httpc prepared capability stays absent until every supported OTP proves exact lines" do
    Code.ensure_loaded!(Httpc)
    refute function_exported?(Httpc, :send_prepared, 2)
  end

  defp listen(ip) do
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet
    {:ok, listener} = :gen_tcp.listen(0, [family, :binary, active: false, ip: ip, reuseaddr: true])
    {:ok, port} = :inet.port(listener)
    {listener, port}
  end

  defp serialize(request) do
    IO.iodata_to_binary([request.method, " ", request.target, " HTTP/1.1\r\n",
      Enum.map(request.headers, fn {name, value} -> [name, ": ", value, "\r\n"] end),
      "\r\n", request.body])
  end

  defp receive_request(listener) do
    {:ok, socket} = :gen_tcp.accept(listener, 5_000)
    try do
      bytes = read_request(socket, "")
      :ok = :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
      bytes
    after
      :gen_tcp.close(socket)
    end
  end

  defp read_request(socket, acc, protocol \\ :gen_tcp) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        [_, length] = Regex.run(~r/\r\ncontent-length: (\d+)/i, head)
        if byte_size(body) == String.to_integer(length), do: acc, else: read_more(socket, acc, protocol)
      _ -> read_more(socket, acc, protocol)
    end
  end

  defp read_more(socket, acc, protocol) do
    {:ok, bytes} = protocol.recv(socket, 0, 5_000)
    read_request(socket, acc <> bytes, protocol)
  end
end
