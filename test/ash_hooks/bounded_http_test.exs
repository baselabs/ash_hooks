defmodule AshHooks.BoundedHttpTest do
  @moduledoc """
  The bounded native adapter (derisk-2): a raw-socket test server we
  fully control speaks exact bytes — the giant NON-2xx body CUT (the
  residual :httpc could not close), chunked assembly under the bound,
  the header-block cap, and the roundtrips (via :inets httpd for
  well-formed serving). TLS + the real world are the live smoke's.
  """

  use ExUnit.Case, async: false

  alias AshHooks.Http.Bounded

  @cap 1_024

  # ── raw server: one connection, one canned response ──────────────

  defp raw_server(response_bytes) do
    parent = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 10_000)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)
      :gen_tcp.send(socket, response_bytes)
      # hold the socket briefly so a bounded reader that keeps reading
      # past its cap would visibly over-read
      :timer.sleep(200)
      :gen_tcp.close(socket)
      :gen_tcp.close(listen)
      send(parent, :served)
    end)

    {"http://127.0.0.1:#{port}", [validate_destination: false]}
  end

  describe "the headline: a giant NON-2xx body is CUT at the bound" do
    test "a 404 with a 200KB body returns status 404 and ≤ cap body" do
      giant = String.duplicate("x", 200_000)

      {base, opts} =
        raw_server(
          "HTTP/1.1 404 Not Found\r\ncontent-length: #{byte_size(giant)}\r\nconnection: close\r\n\r\n" <>
            giant
        )

      assert {:ok, %{status: 404, body: body}} =
               Bounded.request(
                 :get,
                 base <> "/gone",
                 %{},
                 nil,
                 Keyword.put(opts, :max_body_bytes, @cap)
               )

      assert byte_size(body) == @cap
      assert String.duplicate("x", @cap) == body
    end

    test "the same holds for read-to-close framing (no content-length)" do
      giant = String.duplicate("y", 50_000)

      {base, opts} =
        raw_server("HTTP/1.1 500 Internal Server Error\r\nconnection: close\r\n\r\n" <> giant)

      assert {:ok, %{status: 500, body: body}} =
               Bounded.request(
                 :get,
                 base <> "/boom",
                 %{},
                 nil,
                 Keyword.put(opts, :max_body_bytes, @cap)
               )

      assert byte_size(body) == @cap
    end
  end

  describe "chunked framing" do
    test "chunks assemble in order and the bound still holds" do
      chunk_a = String.duplicate("a", 600)
      chunk_b = String.duplicate("b", 600)

      response =
        "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n" <>
          Integer.to_string(byte_size(chunk_a), 16) <>
          "\r\n" <>
          chunk_a <>
          "\r\n" <>
          Integer.to_string(byte_size(chunk_b), 16) <>
          "\r\n" <>
          chunk_b <>
          "\r\n" <>
          "0\r\n\r\n"

      {base, opts} = raw_server(response)

      assert {:ok, %{status: 200, body: body}} =
               Bounded.request(
                 :get,
                 base <> "/chunked",
                 %{},
                 nil,
                 Keyword.put(opts, :max_body_bytes, @cap)
               )

      assert body == chunk_a <> String.duplicate("b", @cap - 600)
    end
  end

  describe "a truncated body never classifies as success" do
    test "a chunked body cut mid-chunk by close is :truncated_body, not a partial ok" do
      # declares a 5-byte chunk, delivers only 3, then the server closes
      {base, opts} =
        raw_server(
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n5\r\nabc"
        )

      assert {:error, :truncated_body} =
               Bounded.request(:get, base <> "/cut-mid-chunk", %{}, nil, opts)
    end

    test "a chunked body cut between chunks (no terminal 0-chunk) is :truncated_body" do
      {base, opts} =
        raw_server(
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n3\r\nabc\r\n"
        )

      assert {:error, :truncated_body} =
               Bounded.request(:get, base <> "/cut-between-chunks", %{}, nil, opts)
    end

    test "a Content-Length body cut by close is :truncated_body (parity with chunked)" do
      {base, opts} =
        raw_server("HTTP/1.1 200 OK\r\ncontent-length: 10\r\nconnection: close\r\n\r\nabc")

      assert {:error, :truncated_body} =
               Bounded.request(:get, base <> "/cut-sized", %{}, nil, opts)
    end

    test "a NEGATIVE chunk-size line is malformed, never a raise" do
      {base, opts} =
        raw_server(
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n-1\r\nabc"
        )

      assert {:error, :malformed_chunked} =
               Bounded.request(:get, base <> "/negative-chunk", %{}, nil, opts)
    end
  end

  describe "the header-block bound" do
    test "an oversized header block is refused, not buffered" do
      huge_header = String.duplicate("h", 40_000)

      {base, opts} =
        raw_server("HTTP/1.1 200 OK\r\nx-big: #{huge_header}\r\nconnection: close\r\n\r\nok")

      assert {:error, :header_block_too_large} =
               Bounded.request(:get, base <> "/headers", %{}, nil, opts)
    end
  end

  describe "shape contracts" do
    test "a refused connection is an error tuple, never a raise" do
      assert {:error, _} =
               Bounded.request(
                 :post,
                 "http://127.0.0.1:1/hook",
                 %{"content-type" => "application/json"},
                 "{}",
                 validate_destination: false
               )
    end

    test "a private literal is refused when validation is on (default)" do
      assert {:error, :unsafe_destination} = Bounded.request(:get, "http://127.0.0.1/x", %{}, nil)
    end

    test "a redirect is returned as-is — never followed" do
      {base, opts} =
        raw_server(
          "HTTP/1.1 302 Found\r\nlocation: http://127.0.0.1:9/evil\r\ncontent-length: 0\r\n\r\n"
        )

      assert {:ok, %{status: 302, headers: headers}} =
               Bounded.request(:post, base <> "/redir", %{}, "{}", opts)

      assert List.keyfind(headers, "location", 0) |> elem(1) =~ "evil"
    end

    test "a malformed status line is an error tuple, never a raise" do
      {base, opts} = raw_server("GARBAGE\r\n\r\n")

      assert {:error, _} = Bounded.request(:get, base <> "/garbage", %{}, nil, opts)
    end
  end

  describe "well-formed serving roundtrip (real :inets httpd)" do
    setup do
      root = Path.join(System.tmp_dir!(), "ash_hooks_bounded_#{System.unique_integer()}")
      File.mkdir_p!(Path.join(root, "logs"))
      File.write!(Path.join(root, "small.json"), ~s({"ok": true}))

      {:ok, pid} =
        :inets.start(:httpd, [
          {:port, 0},
          {:bind_address, ~c"127.0.0.1"},
          {:server_name, ~c"ash_hooks_bounded"},
          {:server_root, ~c"/tmp"},
          {:document_root, String.to_charlist(root)},
          {:mime_types, [{~c"json", ~c"application/json"}]}
        ])

      port = :proplists.get_value(:port, :httpd.info(pid))

      on_exit(fn ->
        :inets.stop(:httpd, pid)
        File.rm_rf(root)
      end)

      %{base: "http://127.0.0.1:#{port}", opts: [validate_destination: false]}
    end

    test "a 200 with content-type + body roundtrips", %{base: base, opts: opts} do
      assert {:ok, %{status: 200, headers: headers, body: body}} =
               Bounded.request(:get, base <> "/small.json", %{}, nil, opts)

      assert body == ~s({"ok": true})
      assert List.keyfind(headers, "content-type", 0) |> elem(1) =~ "application/json"
    end

    test "a 404 status survives with its body", %{base: base, opts: opts} do
      assert {:ok, %{status: 404, body: body}} =
               Bounded.request(:get, base <> "/nope.json", %{}, nil, opts)

      assert is_binary(body)
    end
  end
end
