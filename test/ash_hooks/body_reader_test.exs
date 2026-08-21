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
  end
end
