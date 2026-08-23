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

    test "a non-CRLF chunk terminator is malformed, never silently consumed" do
      # chunk data "abc" then XX instead of CRLF, then a well-formed terminator
      {base, opts} =
        raw_server(
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n3\r\nabcXX0\r\n\r\n"
        )

      assert {:error, :malformed_chunked} =
               Bounded.request(:get, base <> "/bad-terminator", %{}, nil, opts)
    end

    test "a size line that never terminates is malformed once absurd, not buffered" do
      # 200 bytes with no CRLF anywhere — a size line is a hex length; past
      # any sane bound without a terminator the framing is malformed
      {base, opts} =
        raw_server(
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n" <>
            String.duplicate("A", 200)
        )

      assert {:error, :malformed_chunked} =
               Bounded.request(:get, base <> "/runon-size-line", %{}, nil, opts)
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

  # ── scripted server: accepts, hands the request to the test, then runs
  # a send/pause/stall/close script — the harness for split-delivery and
  # mid-frame fault shapes
  defp scripted_server(script) do
    parent = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 10_000)
      {:ok, request} = :gen_tcp.recv(socket, 0, 5_000)
      send(parent, {:request, request})

      Enum.each(script, fn
        {:send, bytes} ->
          :gen_tcp.send(socket, bytes)

        {:pause, ms} ->
          :timer.sleep(ms)

        {:stall, ms} ->
          # hold the connection OPEN without sending — a recv-timeout fault
          :timer.sleep(ms)
          :gen_tcp.close(socket)

        {:close, _} ->
          :gen_tcp.close(socket)
      end)

      :gen_tcp.close(listen)
    end)

    {"http://127.0.0.1:#{port}", [validate_destination: false]}
  end

  describe "request-line shapes" do
    test "a URL with no path requests /" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n",
          close: true
        )

      assert {:ok, %{status: 200}} = Bounded.request(:get, base, %{}, nil, opts)
      assert_receive {:request, request}
      assert String.starts_with?(request, "GET / HTTP/1.1\r\n")
    end

    test "a URL with only a query requests /?query" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n",
          close: true
        )

      assert {:ok, %{status: 200}} = Bounded.request(:get, base <> "?a=1", %{}, nil, opts)
      assert_receive {:request, request}
      assert String.starts_with?(request, "GET /?a=1 HTTP/1.1\r\n")
    end

    test "a URL with path and query requests path?query" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n",
          close: true
        )

      assert {:ok, %{status: 200}} = Bounded.request(:get, base <> "/x/y?b=2", %{}, nil, opts)
      assert_receive {:request, request}
      assert String.starts_with?(request, "GET /x/y?b=2 HTTP/1.1\r\n")
    end
  end

  describe "send failures" do
    test "a peer that closes before reading fails the send as an error tuple" do
      parent = self()

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])

      {:ok, port} = :inet.port(listen)

      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 10_000)
        # Cap OUR receive window (defeats any sysctl autotuning), read a
        # prefix, then HOLD: the client's 512MB send fills the tiny window
        # and BLOCKS in the kernel. RST-on-close while the send is provably
        # blocked — only then does :gen_tcp.send return an error
        :inet.setopts(socket, rcvbuf: 1024)
        {:ok, _prefix} = :gen_tcp.recv(socket, 100, 5_000)
        :timer.sleep(100)
        :inet.setopts(socket, linger: {true, 0})
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
        send(parent, :closed)
      end)

      big_body = String.duplicate("z", 512_000_000)

      # the observable CONTRACT: a dead peer is an error tuple, never a
      # raise. WHERE the failure surfaces is platform-timing: Linux kills
      # the in-flight send ({:send_failed, reason} — the send wrap this
      # test pins for the gate); macOS buffers arbitrarily large sends and
      # the failure surfaces at the read (truncated_response); a losing
      # race puts the RST on the connect itself (econnreset)
      result =
        Bounded.request(
          :post,
          "http://127.0.0.1:#{port}/sink",
          %{},
          big_body,
          validate_destination: false,
          connect_timeout: 1_000
        )

      IO.puts("SEND-FAILURE SHAPE: #{inspect(elem(result, 1))}")

      sysctls = ~w(net.core.wmem_max net.core.rmem_max net.ipv4.tcp_wmem net.ipv4.tcp_rmem)

      IO.puts(
        "send-failure sysctls: " <>
          (sysctls
           |> Enum.map(fn s ->
             "#{s}=#{elem(System.cmd("sysctl", ["-n", s]), 0) |> String.trim()}"
           end)
           |> Enum.join(" "))
      )

      assert {:error, shape} = result

      assert shape in [
               {:send_failed, :closed},
               {:send_failed, :econnreset},
               :truncated_response,
               :econnreset,
               :closed
             ]
    end
  end

  describe "hostile caller bounds still fail closed" do
    test "a negative header cap refuses immediately, never reads unbounded" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n",
          close: true
        )

      assert {:error, :header_block_too_large} =
               Bounded.request(
                 :get,
                 base <> "/neg",
                 %{},
                 nil,
                 Keyword.put(opts, :max_header_bytes, -1)
               )
    end
  end

  describe "a head that never completes" do
    test "a close before the header terminator is :truncated_response" do
      {base, opts} = scripted_server(send: "HTTP/1.1 200 OK\r\nx: 1", close: true)

      assert {:error, :truncated_response} =
               Bounded.request(:get, base <> "/partial-head", %{}, nil, opts)
    end

    test "a server that stalls after the request line is a recv timeout" do
      {base, opts} = scripted_server(stall: 2_000)

      assert {:error, :timeout} =
               Bounded.request(
                 :get,
                 base <> "/stall-head",
                 %{},
                 nil,
                 Keyword.put(opts, :timeout, 150)
               )
    end

    test "a header block with NO terminator is refused at the cap, not buffered" do
      {base, opts} = scripted_server(send: String.duplicate("h", 40_000), stall: 2_000)

      assert {:error, :header_block_too_large} =
               Bounded.request(:get, base <> "/runon", %{}, nil, opts)
    end
  end

  describe "lenient head parsing" do
    test "a status line without a reason phrase still parses" do
      {base, opts} =
        scripted_server(send: "HTTP/1.1 200\r\ncontent-length: 2\r\n\r\nok", close: true)

      assert {:ok, %{status: 200, body: "ok"}} =
               Bounded.request(:get, base <> "/minimal", %{}, nil, opts)
    end

    test "a header line without a colon is skipped, the rest survive" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ngarbage-line\r\ncontent-length: 2\r\n\r\nok",
          close: true
        )

      assert {:ok, %{status: 200, headers: headers, body: "ok"}} =
               Bounded.request(:get, base <> "/junk", %{}, nil, opts)

      assert List.keyfind(headers, "content-length", 0) == {"content-length", "2"}
      refute Enum.any?(headers, fn {name, _} -> String.contains?(name, "garbage") end)
    end

    test "an unparseable content-length is :malformed_content_length" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: banana\r\n\r\nok",
          close: true
        )

      assert {:error, :malformed_content_length} =
               Bounded.request(:get, base <> "/banana", %{}, nil, opts)
    end
  end

  describe "body framing faults" do
    test "a sized body straddling pulls reassembles" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 5\r\n\r\nhel",
          pause: 60,
          send: "lo",
          close: true
        )

      assert {:ok, %{status: 200, body: "hello"}} =
               Bounded.request(:get, base <> "/split-sized", %{}, nil, opts)
    end

    test "a sized body whose server stalls mid-body is a recv timeout" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc",
          stall: 2_000
        )

      assert {:error, :timeout} =
               Bounded.request(
                 :get,
                 base <> "/stall-sized",
                 %{},
                 nil,
                 Keyword.put(opts, :timeout, 150)
               )
    end

    test "a complete small chunked body assembles via the terminal 0-chunk" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n",
          close: true
        )

      assert {:ok, %{status: 200, body: "abc"}} =
               Bounded.request(:get, base <> "/whole", %{}, nil, opts)
    end

    test "a size line delivered in a later pull is awaited, not misread" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n3\r\nabc\r\n",
          pause: 60,
          send: "0\r\n\r\n",
          close: true
        )

      assert {:ok, %{status: 200, body: "abc"}} =
               Bounded.request(:get, base <> "/late-size", %{}, nil, opts)
    end

    test "a chunk whose data straddles pulls is reassembled" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nab",
          pause: 60,
          send: "cde\r\n0\r\n\r\n",
          close: true
        )

      assert {:ok, %{status: 200, body: "abcde"}} =
               Bounded.request(:get, base <> "/split-chunk", %{}, nil, opts)
    end

    test "a stalled size line is a recv timeout" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5",
          stall: 2_000
        )

      assert {:error, :timeout} =
               Bounded.request(
                 :get,
                 base <> "/stall-size",
                 %{},
                 nil,
                 Keyword.put(opts, :timeout, 150)
               )
    end

    test "a non-hex size line is malformed" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\nzz\r\nabc",
          stall: 2_000
        )

      assert {:error, :malformed_chunked} =
               Bounded.request(:get, base <> "/zz", %{}, nil, opts)
    end
  end

  describe "the discard path (declared chunk beyond the allowance)" do
    test "an excess split across pulls is discarded slice-wise and framing completes" do
      {base, opts} =
        scripted_server(
          send:
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n10\r\n" <>
              String.duplicate("A", 12),
          pause: 60,
          send: "AAAA\r\n0\r\n\r\n",
          close: true
        )

      assert {:ok, %{status: 200, body: body}} =
               Bounded.request(
                 :get,
                 base <> "/excess",
                 %{},
                 nil,
                 Keyword.put(opts, :max_body_bytes, 8)
               )

      assert body == "AAAAAAAA"
    end

    test "a close during the discard is :truncated_body" do
      {base, opts} =
        scripted_server(
          send:
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n10\r\n" <>
              String.duplicate("A", 8),
          close: true
        )

      assert {:error, :truncated_body} =
               Bounded.request(
                 :get,
                 base <> "/discard-cut",
                 %{},
                 nil,
                 Keyword.put(opts, :max_body_bytes, 8)
               )
    end

    test "a stall during the discard is a recv timeout" do
      {base, opts} =
        scripted_server(
          send:
            "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n10\r\n" <>
              String.duplicate("A", 8),
          stall: 2_000
        )

      assert {:error, :timeout} =
               Bounded.request(
                 :get,
                 base <> "/discard-stall",
                 %{},
                 nil,
                 Keyword.merge(opts, max_body_bytes: 8, timeout: 150)
               )
    end

    test "a stall while taking chunk data is a recv timeout" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nab",
          stall: 2_000
        )

      assert {:error, :timeout} =
               Bounded.request(
                 :get,
                 base <> "/take-stall",
                 %{},
                 nil,
                 Keyword.merge(opts, timeout: 150)
               )
    end
  end

  describe "read-to-close framing (no content-length, no chunked)" do
    test "a small body delivered with the close completes" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nhello",
          close: true
        )

      assert {:ok, %{status: 200, body: "hello"}} =
               Bounded.request(:get, base <> "/bye", %{}, nil, opts)
    end

    test "a body straddling pulls reassembles until the close" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nhel",
          pause: 60,
          send: "lo",
          close: true
        )

      assert {:ok, %{status: 200, body: "hello"}} =
               Bounded.request(:get, base <> "/split-close", %{}, nil, opts)
    end

    test "a stall before the close is a recv timeout" do
      {base, opts} =
        scripted_server(
          send: "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\nhel",
          stall: 2_000
        )

      assert {:error, :timeout} =
               Bounded.request(
                 :get,
                 base <> "/close-stall",
                 %{},
                 nil,
                 Keyword.put(opts, :timeout, 150)
               )
    end
  end

  describe "TLS refusal shape (no handshake needed)" do
    test "an https URL on a closed port is a connect error, never a raise" do
      assert {:error, _reason} =
               Bounded.request(
                 :get,
                 "https://127.0.0.1:1/x",
                 %{},
                 nil,
                 validate_destination: false,
                 connect_timeout: 500
               )
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
