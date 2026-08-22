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
end
