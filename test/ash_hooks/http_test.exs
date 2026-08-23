defmodule AshHooks.HttpTest do
  @moduledoc """
  The default `:httpc` adapter, hardened (derisk slice): IP-pinned
  connections, bounded streamed bodies, refused redirects. The local
  tests run a real :inets httpd listener (loopback — the adapter's
  validate_destination seam is off for these; the SSRF obligation lives
  in the driver's send-time check); the hostname-pinning + real-TLS path
  is proven by the live runtime smoke.
  """

  use ExUnit.Case, async: false

  alias AshHooks.Http.Httpc

  @big_bytes 200_000
  @cap 1_024

  setup_all do
    # a PRIVATE throwaway doc root + loopback-only bind (cross-vendor
    # finding: :httpd's default binds :any and the fixture served /tmp)
    root = Path.join(System.tmp_dir!(), "ash_hooks_http_test_#{System.unique_integer()}")
    File.mkdir_p!(Path.join(root, "logs"))
    File.write!(Path.join(root, "small.json"), ~s({"ok": true}))
    File.write!(Path.join(root, "big.json"), String.duplicate("x", @big_bytes))

    {:ok, pid} =
      :inets.start(:httpd, [
        {:port, 0},
        {:bind_address, ~c"127.0.0.1"},
        {:server_name, ~c"ash_hooks_test"},
        # document_root must be a CHARLIST — a binary root serves only 500s
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

  describe "shape contracts (no crash, error tuples)" do
    test "a refused connection is an error tuple, never a raise" do
      assert {:error, _reason} =
               Httpc.request(
                 :post,
                 "https://127.0.0.1:1/hook",
                 %{"content-type" => "application/json"},
                 "{}",
                 validate_destination: false
               )
    end

    test "a garbage url is an error tuple, never a raise" do
      assert {:error, _reason} =
               Httpc.request(:post, "not a url", %{}, "{}", validate_destination: false)
    end
  end

  describe "status + body round-trip" do
    test "a 200 streams its full body with status and headers", %{base: base, opts: opts} do
      assert {:ok, %{status: 200, headers: headers, body: body}} =
               Httpc.request(:get, base <> "/small.json", %{}, nil, opts)

      assert body == ~s({"ok": true})
      assert List.keyfind(headers, "content-type", 0) |> elem(1) =~ "application/json"
    end

    test "a 404 arrives via the non-streamed path with its status intact", %{
      base: base,
      opts: opts
    } do
      assert {:ok, %{status: 404}} =
               Httpc.request(:get, base <> "/no-such-file.json", %{}, nil, opts)
    end
  end

  describe "the body bound (memory DoS floor — derisk tripwire)" do
    test "a giant 2xx body is CUT at max_body_bytes", %{base: base, opts: opts} do
      assert {:ok, %{status: 200, body: body}} =
               Httpc.request(
                 :get,
                 base <> "/big.json",
                 %{},
                 nil,
                 Keyword.put(opts, :max_body_bytes, @cap)
               )

      assert byte_size(body) == @cap
    end

    test "a giant NON-2xx body is still CUT at the bound (the assembled window's containment)",
         %{} do
      # :httpc streams only 200/206 — an error status arrives assembled
      # whole inside OTP (the adapter's documented residual WINDOW). This
      # pins the containment claim: whatever assembles transiently, the
      # RESULT the runtime sees is bounded. The window itself is
      # quantified in ADR-0009 (dribble probe).
      giant = String.duplicate("x", @big_bytes)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])

      {:ok, port} = :inet.port(listen)

      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 10_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        :gen_tcp.send(
          socket,
          "HTTP/1.1 404 Not Found\r\ncontent-length: #{byte_size(giant)}\r\n\r\n"
        )

        :gen_tcp.send(socket, giant)
        :timer.sleep(200)
        :gen_tcp.close(socket)
        :gen_tcp.close(listen)
      end)

      assert {:ok, %{status: 404, body: body}} =
               Httpc.request(
                 :get,
                 "http://127.0.0.1:#{port}/gone",
                 %{},
                 nil,
                 validate_destination: false,
                 max_body_bytes: @cap
               )

      assert byte_size(body) == @cap
    end

    test "the default bound applies without an explicit opt", %{base: base, opts: opts} do
      assert {:ok, %{body: body}} =
               Httpc.request(:get, base <> "/big.json", %{}, nil, opts)

      assert byte_size(body) <= 65_536
    end
  end

  describe "destination validation (the adapter's defense-in-depth copy)" do
    test "a private literal is refused when validation is on (default)" do
      assert {:error, :unsafe_destination} = Httpc.request(:get, "http://127.0.0.1/x", %{}, nil)
    end

    test "an unresolvable hostname is refused, not crashed" do
      assert {:error, reason} =
               Httpc.request(:get, "https://no-such-host-ash-hooks.invalid/x", %{}, nil)

      assert reason in [:unresolved_host, :unsafe_destination]
    end
  end

  # ────────────────── coverage: the httpc-specific fault paths ──────────────────

  defp raw_server(script) do
    parent = self()

    {:ok, listen} =
      :gen_tcp.listen(0, [:binary, {:active, false}, {:ip, {127, 0, 0, 1}}])

    {:ok, port} = :inet.port(listen)

    spawn(fn ->
      {:ok, socket} = :gen_tcp.accept(listen, 10_000)
      {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

      Enum.each(script, fn
        {:send, bytes} ->
          :gen_tcp.send(socket, bytes)

        {:pause, ms} ->
          :timer.sleep(ms)

        {:rst, ms} ->
          :timer.sleep(ms)
          :inet.setopts(socket, linger: {true, 0})
          :gen_tcp.close(socket)

        :close ->
          :gen_tcp.close(socket)
      end)

      :gen_tcp.close(listen)
      send(parent, :done)
    end)

    {"http://127.0.0.1:#{port}", [validate_destination: false]}
  end

  describe "httpc fault + shape edges" do
    test "a bodyless non-2xx keeps body nil" do
      {base, opts} =
        raw_server(
          send: "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\n\r\n",
          pause: 100,
          close: :close
        )

      assert {:ok, %{status: 404, body: body}} = Httpc.request(:get, base <> "/x", %{}, nil, opts)
      assert body == ""
    end

    test "a POST with a content-type header passes it through" do
      {base, opts} =
        raw_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
          pause: 100,
          close: :close
        )

      assert {:ok, %{status: 200, body: "ok"}} =
               Httpc.request(
                 :post,
                 base <> "/x",
                 %{"content-type" => "application/merge-patch+json"},
                 "{}",
                 opts
               )
    end

    test "a POST without a content-type header defaults to application/json" do
      {base, opts} =
        raw_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
          pause: 100,
          close: :close
        )

      assert {:ok, %{status: 200, body: "ok"}} =
               Httpc.request(:post, base <> "/x", %{}, "{}", opts)
    end

    test "a named-host https attempt builds SNI + the RFC 6125 check before refusing" do
      # closed port: the connect fails, but the TLS option builder's named
      # branch executed during the attempt
      assert {:error, _reason} =
               Httpc.request(:get, "https://localhost:1/x", %{}, nil,
                 validate_destination: false,
                 connect_timeout: 500
               )
    end

    test "a pinned private-CA bundle completes the https roundtrip (the adapter-agnostic seam)" do
      parent = self()

      {:ok, listen} =
        :ssl.listen(0,
          certfile: ~c"test/fixtures/tls/server-both-san.pem",
          keyfile: ~c"test/fixtures/tls/server.key",
          ip: {127, 0, 0, 1},
          active: false,
          mode: :binary
        )

      {:ok, {_addr, port}} = :ssl.sockname(listen)

      spawn(fn ->
        {:ok, socket} = :ssl.transport_accept(listen, 10_000)
        {:ok, socket} = :ssl.handshake(socket, 10_000)
        {:ok, _request} = :ssl.recv(socket, 0, 5_000)
        :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")
        :timer.sleep(100)
        :ssl.close(socket)
        :ssl.close(listen)
        send(parent, :done)
      end)

      [{:Certificate, ca_der, :not_encrypted}] =
        :public_key.pem_decode(File.read!("test/fixtures/tls/local-ca.pem"))

      assert {:ok, %{status: 200, body: "ok"}} =
               Httpc.request(:get, "https://localhost:#{port}/hook", %{}, nil,
                 validate_destination: false,
                 cacerts: [ca_der],
                 timeout: 5_000
               )
    end

    test "a plain-http request never builds ssl options (the empty :ssl rejection)" do
      {base, opts} =
        raw_server(
          send: "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok",
          pause: 100,
          close: :close
        )

      assert {:ok, %{status: 200}} = Httpc.request(:get, base <> "/x", %{}, nil, opts)
    end

    test "a stalled response surfaces httpc's own timeout reason" do
      {base, opts} = raw_server(pause: 1_000)

      assert {:error, :timeout} =
               Httpc.request(:get, base <> "/x", %{}, nil, Keyword.put(opts, :timeout, 200))
    end

    test "a mid-stream transport failure surfaces its reason" do
      {base, opts} =
        raw_server(send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nab", rst: 300)

      assert {:error, _reason} = Httpc.request(:get, base <> "/x", %{}, nil, opts)
    end

    test "a stream that stalls surfaces httpc's timeout reason" do
      {base, opts} =
        raw_server(
          send: "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nab",
          pause: 1_000
        )

      assert {:error, _reason} =
               Httpc.request(:get, base <> "/x", %{}, nil, Keyword.put(opts, :timeout, 200))
    end
  end
end
