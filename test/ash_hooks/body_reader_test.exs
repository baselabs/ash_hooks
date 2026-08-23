# Plug is absent on the no-optional CI leg — the whole test module is
# skipped there (the module itself is conditionally compiled the same way).
if Code.ensure_loaded?(Plug.Conn) do
  defmodule AshHooks.BodyReaderTest do
    @moduledoc "Raw pre-parser byte capture for signature verification."

    use ExUnit.Case, async: true

    test "read_body/2 returns the body and caches the exact bytes privately" do
      conn = Plug.Test.conn("POST", "/webhooks/complycube", ~s({"id":"evt_1"}))

      assert {:ok, body, conn} = AshHooks.BodyReader.read_body(conn, [])

      assert body == ~s({"id":"evt_1"})
      assert conn.private[:ash_hooks_raw_body] == ~s({"id":"evt_1"})
    end

    test "the cached bytes are the wire bytes, not a re-encoding" do
      # whitespace and key order must survive — signature schemes sign the
      # exact bytes the provider sent
      raw = ~s({ "id" : "evt_1" ,  "type":"check.completed" })

      conn = Plug.Test.conn("POST", "/webhooks", raw)
      {:ok, _body, conn} = AshHooks.BodyReader.read_body(conn, [])

      assert conn.private[:ash_hooks_raw_body] == raw
    end

    test ":only wiring works through real Plug.Parsers (extras arrive positionally)" do
      # exactly the documented wiring — Plug.Parsers applies the MFA as
      # apply(mod, fun, [conn, opts | args]), so this is the arity the
      # parser really calls
      parser =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason,
          body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}
        )

      conn =
        Plug.Test.conn("POST", "/webhooks/complycube", ~s({"id":"evt_1"}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Plug.Parsers.call(conn, parser)

      assert conn.private[:ash_hooks_raw_body] == ~s({"id":"evt_1"})
      assert conn.body_params == %{"id" => "evt_1"}
    end

    test ":only wiring through real Plug.Parsers skips non-matching paths" do
      parser =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason,
          body_reader: {AshHooks.BodyReader, :read_body, [only: ["/webhooks"]]}
        )

      conn =
        Plug.Test.conn("POST", "/api/orders", ~s({"order":1}))
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Plug.Parsers.call(conn, parser)

      assert conn.body_params == %{"order" => 1}
      refute Map.has_key?(conn.private, :ash_hooks_raw_body)
    end

    test "a non-canonical routable path (//webhooks/x) still caches" do
      # Plug.Test normalizes the path on conn build, so construct the
      # real-adapter shape directly: raw request_path retains the doubled
      # slash while path_info carries the collapsed router segments
      conn =
        Plug.Test.conn("POST", "/webhooks/x", ~s({"id":"evt_1"}))
        |> struct!(request_path: "//webhooks/x")

      assert {:ok, _body, conn} = AshHooks.BodyReader.read_body(conn, only: ["/webhooks"])

      assert conn.private[:ash_hooks_raw_body] == ~s({"id":"evt_1"})
    end

    test "only: [] behaves as unset (cache everything), never cache-nowhere" do
      conn = Plug.Test.conn("POST", "/api/anything", ~s({"x":1}))

      assert {:ok, _body, conn} = AshHooks.BodyReader.read_body(conn, only: [])

      assert conn.private[:ash_hooks_raw_body] == ~s({"x":1})
    end

    test "with :only, a matching path prefix caches as usual" do
      conn = Plug.Test.conn("POST", "/webhooks/complycube", ~s({"id":"evt_1"}))

      assert {:ok, body, conn} =
               AshHooks.BodyReader.read_body(conn, only: ["/webhooks"])

      assert body == ~s({"id":"evt_1"})
      assert conn.private[:ash_hooks_raw_body] == ~s({"id":"evt_1"})
    end

    test "with :only, a non-matching path passes through with NO cache" do
      conn = Plug.Test.conn("POST", "/api/orders", ~s({"order":1}))

      assert {:ok, body, conn} =
               AshHooks.BodyReader.read_body(conn, only: ["/webhooks"])

      assert body == ~s({"order":1})
      refute Map.has_key?(conn.private, :ash_hooks_raw_body)
    end

    test "with :only, chunked non-matching reads never accumulate anything" do
      raw = String.duplicate("z", 2_000)

      conn = Plug.Test.conn("POST", "/api/orders", raw)

      conn =
        Enum.reduce_while(1..100, conn, fn _, conn ->
          case AshHooks.BodyReader.read_body(conn, only: ["/webhooks"], read_length: 64) do
            {:more, _chunk, conn} -> {:cont, conn}
            {:ok, _chunk, conn} -> {:halt, conn}
          end
        end)

      refute Map.has_key?(conn.private, :ash_hooks_raw_body)
    end

    test "chunked reads accumulate — the cache holds the FULL body, not the last chunk" do
      raw = String.duplicate("a", 10_000) <> ~s({"id":"evt_chunked"})

      conn = Plug.Test.conn("POST", "/webhooks", raw)

      # force the multi-chunk path: tiny read lengths make Plug.Conn.read_body
      # return {:more, ...} until the body is exhausted
      conn =
        Enum.reduce_while(1..100, conn, fn _, conn ->
          case AshHooks.BodyReader.read_body(conn, length: 100_000, read_length: 64) do
            {:more, _chunk, conn} -> {:cont, conn}
            {:ok, _chunk, conn} -> {:halt, conn}
          end
        end)

      assert conn.private[:ash_hooks_raw_body] == raw
    end

    describe "chunked + faulted reads" do
      test "a body larger than the read length arrives as {:more} chunks, all cached" do
        raw = String.duplicate("x", 10)
        conn = Plug.Test.conn("POST", "/webhooks", raw)

        assert {:more, first, conn} = AshHooks.BodyReader.read_body(conn, length: 4)
        assert byte_size(first) == 4

        {chunks, conn} =
          Enum.reduce_while(Stream.repeatedly(fn -> :ok end), {[first], conn}, fn _,
                                                                                  {acc, conn} ->
            case AshHooks.BodyReader.read_body(conn, length: 4) do
              {:more, chunk, conn} -> {:cont, {[chunk | acc], conn}}
              {:ok, last, conn} -> {:halt, {[last | acc], conn}}
            end
          end)

        assert IO.iodata_to_binary(Enum.reverse(chunks)) == raw
        assert conn.private[:ash_hooks_raw_body] == raw
      end

      test "a faulted read surfaces the error and caches nothing" do
        defmodule ErrorAdapter do
          @moduledoc false
          def read_req_body(_conn, _opts), do: {:error, :closed}
        end

        conn = %Plug.Conn{
          adapter: {ErrorAdapter, nil},
          method: "POST",
          req_headers: [],
          path_params: %{},
          private: %{}
        }

        assert {:error, :closed} = AshHooks.BodyReader.read_body(conn, [])
      end
    end
  end
end
