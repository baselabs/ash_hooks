if Code.ensure_loaded?(Req.Request) and Code.ensure_loaded?(Bandit) do
  defmodule AshHooks.EgressReqAdapterTest do
    use ExUnit.Case, async: false

    alias AshHooks.Egress
    alias AshHooks.Egress.{Error, ReqAdapter}

    defmodule FailureCollector do
      defstruct [:owner, :failure]
    end

    defimpl Collectable, for: FailureCollector do
      def into(collectable) do
        {[], fn acc, command ->
          case {command, collectable.failure} do
            {{:cont, _}, :data} -> raise "collector-sentinel"
            {:done, :done} -> throw("collector-sentinel")
            {:halt, :halt} -> exit("collector-sentinel")
            {:halt, _} -> send(collectable.owner, {:collector_halted, acc})
            {{:cont, bytes}, _} -> [bytes | acc]
            {:done, _} -> Enum.reverse(acc)
          end
        end}
      end
    end

    defmodule Receiver do
      def init(owner), do: owner

      def call(conn, owner) do
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(owner, {:bandit_request, conn.method, conn.request_path, body})

        case conn.request_path do
          "/sse" ->
            conn = Plug.Conn.send_chunked(conn, 200)
            {:ok, conn} = Plug.Conn.chunk(conn, "data: {\"a\":")
            :timer.sleep(20)
            {:ok, conn} = Plug.Conn.chunk(conn, "1}\n\ndata: done\n\n")
            conn

          "/redirect" ->
            conn
            |> Plug.Conn.put_resp_header("location", "/target")
            |> Plug.Conn.send_resp(302, "")

          "/429" ->
            Plug.Conn.send_resp(conn, 429, "limited")

          "/503" ->
            Plug.Conn.send_resp(conn, 503, "unavailable")

          _ ->
            Plug.Conn.send_resp(conn, 200, body)
        end
      end
    end

    setup do
      server =
        start_supervised!(
          {Bandit, plug: {Receiver, self()}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
        )

      {:ok, {_, port}} = ThousandIsland.listener_info(server)
      url = "http://127.0.0.1:#{port}"
      {:ok, destination} = Egress.destination(url, allow_http: true, validate_destination: false)
      %{url: url, destination: destination}
    end

    test "real Bandit receives a buffered Req body once", ctx do
      request = request(ctx, "/echo", method: :post, body: ["exact", " body"])

      assert {:ok, %Req.Response{status: 200, body: "exact body"} = response} =
               Req.request(request)

      assert response.private.ash_hooks_completion == :complete
      assert_receive {:bandit_request, "POST", "/echo", "exact body"}
      refute_receive {:bandit_request, _, _, _}, 30
    end

    test "429/503 with a ReqLLM-shaped retry function and zero retries sends exactly once", ctx do
      for status <- [429, 503] do
        retry = fn _request, %Req.Response{status: code} -> code in [429, 503] end
        req = request(ctx, "/#{status}", retry: retry, max_retries: 0)
        assert {:ok, %Req.Response{status: ^status}} = Req.request(req)
        assert_receive {:bandit_request, "GET", _, ""}
        refute_receive {:bandit_request, _, _, _}, 30
        req = request(ctx, "/#{status}", retry: :safe_transient)
        assert {:error, %Error{reason: :retry_not_disabled, sent: :none}} = Req.request(req)
        refute_receive {:bandit_request, _, _, _}, 30

        assert {:ok, %Req.Response{status: ^status}} =
                 Req.request(request(ctx, "/#{status}", retry: :safe_transient, max_retries: 0))

        assert_receive {:bandit_request, _, _, _}
      end
    end

    test "redirect flags and any follow_redirects option are refused before I/O", ctx do
      for options <- [[redirect: true], [redirect: "yes"], [follow_redirects: false], [follow_redirects: true]] do
        assert {:error, %Error{reason: :redirect_refused, sent: :none}} =
                 Req.request(request(ctx, "/redirect", options))
      end

      req = request(ctx, "/redirect")

      assert {:error, %Error{reason: :redirect_refused, sent: :possible, status: 302}} =
               Req.request(req)

      assert_receive {:bandit_request, "GET", "/redirect", ""}
      refute_receive {:bandit_request, _, "/target", _}, 30
    end

    test "Req retry count and the returned attempt latch block any second run", ctx do
      req = request(ctx, "/echo")
      {returned, %Req.Response{status: 200}} = ReqAdapter.run(req)
      assert_receive {:bandit_request, _, _, _}
      assert {_, %Error{reason: :repeat_attempt_refused, sent: :none}} = ReqAdapter.run(returned)
      req = Req.Request.put_private(req, :req_retry_count, 1)
      assert {_, %Error{reason: :repeat_attempt_refused, sent: :none}} = ReqAdapter.run(req)
      refute_receive {:bandit_request, _, _, _}, 30
    end

    test "SSE into callback preserves split bytes and response head", ctx do
      callback = fn {:data, bytes}, {request, response} ->
        {:cont, {request, %{response | body: response.body <> bytes}}}
      end

      assert {:ok, response} = Req.request(request(ctx, "/sse", into: callback))
      assert response.body == "data: {\"a\":1}\n\ndata: done\n\n"
      assert response.status == 200
      assert response.headers["transfer-encoding"] == ["chunked"]
      assert response.private.ash_hooks_completion == :complete
    end

    test "callback halt keeps the latch even if the callback returns a fresh request", ctx do
      callback = fn {:data, _}, {_req, resp} -> {:halt, {request(ctx, "/echo"), resp}} end
      {returned, response} = ReqAdapter.run(request(ctx, "/sse", into: callback))
      assert response.private.ash_hooks_completion == :halted
      assert {_, %Error{reason: :repeat_attempt_refused}} = ReqAdapter.run(returned)
    end

    test "callback failure is classified without its values", ctx do
      callback = fn _, _ -> raise "req-callback-sentinel" end

      assert {:error, %Error{reason: :callback_failed, sent: :possible}} =
               Req.request(request(ctx, "/sse", into: callback))

      assert {:error, %Error{reason: :callback_failed}} =
               Req.request(request(ctx, "/sse", into: fn _, _ -> {:cont, :invalid} end))
    end

    test "collectable failures and truncated streams halt collection without retaining terms", ctx do
      for failure <- [:data, :done] do
        collector = %FailureCollector{owner: self(), failure: failure}
        assert {:error, %Error{reason: :callback_failed, sent: :possible}} =
                 Req.request(request(ctx, "/sse", into: collector))
        assert_receive {:collector_halted, _}
      end

      for failure <- [:halt, nil] do
        collector = %FailureCollector{owner: self(), failure: failure}
        req = raw_request("HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\ndata: partial\n\n", into: collector)
        assert {:error, %Error{reason: :truncated_body, sent: :possible}} = Req.request(req)
        if is_nil(failure), do: assert_receive({:collector_halted, _})
      end

      req = raw_request("HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n")
      assert {:error, %Error{reason: :truncated_body}} = Req.request(%{req | into: []})
      assert {:error, %Error{reason: :callback_failed}} =
               Req.request(request(ctx, "/sse", into: :not_collectable))
    end

    test "collectable receives 200 body and other statuses accumulate a binary", ctx do
      assert {:ok, %Req.Response{body: body}} = Req.request(request(ctx, "/sse", into: []))
      assert IO.iodata_to_binary(body) == "data: {\"a\":1}\n\ndata: done\n\n"

      assert {:ok, %Req.Response{body: "unavailable"}} =
               Req.request(request(ctx, "/503", into: []))

      path =
        Path.join(System.tmp_dir!(), "ash-hooks-egress-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm(path) end)

      assert {:ok, %Req.Response{body: %File.Stream{}}} =
               Req.request(request(ctx, "/sse", into: File.stream!(path)))

      assert File.read!(path) == "data: {\"a\":1}\n\ndata: done\n\n"
    end

    test "invalid destinations, body streams, async streams and defaults fail before I/O", ctx do
      req = request(ctx, "/echo")

      assert {_, %Error{reason: :invalid_request, sent: :none}} =
               ReqAdapter.run(%{req | body: Stream.map(["a"], & &1)})

      assert {_, %Error{reason: :invalid_request, sent: :none}} =
               ReqAdapter.run(%{req | into: :self})

      assert {_, %Error{reason: :destination_mismatch, sent: :none}} =
               ReqAdapter.run(Req.Request.put_private(req, :ash_hooks_destination, nil))

      assert {_, %Error{reason: :retry_not_disabled, sent: :none}} =
               ReqAdapter.run(Req.new(url: ctx.url))

      assert {_, %Error{reason: :redirect_refused, sent: :none}} =
               ReqAdapter.run(Req.new(url: ctx.url, retry: false))

      refute_receive {:bandit_request, _, _, _}, 30
    end

    defp request(ctx, path, options \\ []) do
      [
        url: ctx.url <> path,
        adapter: ReqAdapter,
        redirect: false,
        retry: false,
        decode_body: false
      ]
      |> Keyword.merge(options)
      |> Req.new()
      |> Req.Request.put_private(:ash_hooks_destination, ctx.destination)
    end

    defp raw_request(bytes, opts \\ []) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, port} = :inet.port(listener)

      peer = spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3_000)
        {:ok, _} = :gen_tcp.recv(socket, 0, 3_000)
        :gen_tcp.send(socket, bytes)
        :gen_tcp.close(socket)
      end)

      on_exit(fn ->
        :gen_tcp.close(listener)
        Process.exit(peer, :kill)
      end)

      url = "http://127.0.0.1:#{port}"
      {:ok, destination} = Egress.destination(url, allow_http: true, validate_destination: false)
      request(%{url: url, destination: destination}, "/", opts)
    end
  end
end
