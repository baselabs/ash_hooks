defmodule AshHooks.EgressTest do
  use ExUnit.Case, async: false

  alias AshHooks.Egress
  alias AshHooks.Egress.{Destination, Error, Response}
  alias AshHooks.Http.Bounded
  alias AshHooks.Test.EgressEvents

  test "enrollment stores plain authority, path, pin and opaque identifier without DNS" do
    assert {:ok, destination} =
             Egress.destination("https://NO-SUCH-HOST.invalid/v1", destination_id: "opaque")

    assert %Destination{
             host: "no-such-host.invalid",
             scheme: "https",
             port: 443,
             path_prefix: "/v1",
             id: "opaque",
             validate_destination: true
           } = destination

    assert {:ok, %Destination{port: 8443, path_prefix: "/"}} =
             Egress.destination("https://example.com:8443")

    assert {:ok, %Destination{path_prefix: "/api"}} =
             Egress.destination("https://example.com/", path_prefix: "/api")

    for url <- [
          nil,
          "https://user:password@example.com/api",
          "http://example.com",
          "https://127.0.0.1",
          "https://metadata.google.internal",
          "file:///etc/passwd",
          "https://example.com/#fragment",
          "https://example.com:0/",
          "https://example.com/a/../b",
          "https://example.com/%2e%2e/b",
          "https://example.com/a%5cb"
        ] do
      assert {:error, %Error{reason: :unsafe_destination, sent: :none}} = Egress.destination(url)
    end

    assert {:error, %Error{reason: :unsafe_destination}} =
             Egress.destination("https://example.com", path_prefix: nil)

    assert {:error, %Error{reason: :invalid_certificate_pin}} =
             Egress.destination("https://example.com", certificate_pin: :bad)

    assert {:error, %Error{reason: :certificate_pin_requires_https}} =
             Egress.destination("http://example.com",
               allow_http: true,
               certificate_pin: {:sha256, <<0::256>>}
             )
  end

  test "effective authority and path scope are checked before any socket I/O" do
    {url, _server} = server([])
    destination = enroll(url <> "/v1")

    for target <- [
          "https://127.0.0.1/",
          "http://localhost/",
          url <> "/v10",
          url <> "/v1/%2e%2e/escape",
          url <> "/other",
          123,
          "http://user:password@127.0.0.1/",
          "http://[",
          "//example.com/v1"
        ] do
      assert {:error, %Error{reason: :destination_mismatch, phase: :validate, sent: :none}} =
               Egress.request(destination, :get, target, %{}, nil)
    end

    assert {:error, %Error{reason: :destination_mismatch}} =
             Egress.request(nil, :get, url, %{}, nil)

    assert {:error, %Error{reason: :destination_mismatch}} =
             Egress.request(%{destination | allow_http: false}, :get, url <> "/v1", %{}, nil)

    assert {:error, %Error{reason: :destination_mismatch, sent: :none}} =
             Egress.request(%{destination | port: :invalid}, :get, "/v1", %{}, nil)

    refute_receive {:received, _}, 30
  end

  test "public validation returns value-free errors and never turns data into atoms" do
    {url, _} = server([])
    destination = enroll(url)

    for method <- [:unknown, "unrecognized", 42, <<255>>] do
      assert {:error, %Error{reason: :unsupported_method, sent: :none}} =
               Egress.request(destination, method, url, %{}, nil)
    end

    for {headers, body, reason} <- [
          {%{"host" => "elsewhere"}, nil, :invalid_request},
          {%{"x" => "a\r\nb"}, nil, :invalid_header_value},
          {%{"bad name" => "a"}, nil, :invalid_header_name},
          {%{}, :bad_body, :invalid_request},
          {:bad_headers, nil, :invalid_request}
        ] do
      assert {:error, %Error{reason: ^reason, sent: :none}} =
               Egress.request(destination, :get, url, headers, body)
    end

    assert {:error, %Error{reason: :invalid_request}} =
             Egress.stream(destination, :get, url, %{}, nil, :not_a_function, nil)

    for opts <- [[timeout: -1], [max_body_bytes: -1], [idle_timeout: nil]] do
      assert {:error, %Error{reason: :invalid_options, sent: :none}} =
               Egress.request(destination, :get, url, %{}, nil, opts)
    end

    assert {:error, error} = Egress.request(nil, :get, "sensitive-url", %{}, nil)
    assert Exception.message(error) == "egress request failed"

    assert inspect(%{error | reason: "sentinel", status: "sentinel"}) ==
             "#AshHooks.Egress.Error<>"

    assert_raise Error, "egress request failed", fn -> raise error end

    assert %Error{reason: :unsafe_destination, phase: :validate, sent: :none} =
             Error.exception(reason: :unsafe_destination, phase: :validate, sent: :none)
  end

  test "an enrolled public policy cannot be bypassed per request; DNS refusal is unsent" do
    assert {:ok, destination} = Egress.destination("https://localhost/")

    assert {:error, %Error{reason: :unsafe_destination, phase: :resolve, sent: :none}} =
             Egress.request(destination, :get, "/", %{}, nil, validate_destination: false)

    assert {:ok, missing} = Egress.destination("https://no-such-egress-test.invalid/")

    assert {:error, %Error{reason: :unresolved_host, sent: :none}} =
             Egress.request(missing, :get, "/", %{}, nil)
  end

  test "buffered bytes and path-query are exact, with case-insensitive fixed methods" do
    {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 5\r\nx-answer: yes\r\n\r\nhello")

    assert {:ok,
            %Response{status: 200, body: "hello", completion: :complete, acc: nil} = response} =
             Egress.request(enroll(url), "pOsT", "/v1?q=1", %{"x-extra" => "value"}, "request")

    assert {"x-answer", "yes"} in response.headers
    assert_receive {:received, bytes}
    assert bytes =~ "POST /v1?q=1 HTTP/1.1\r\n"
    assert bytes =~ "host: 127.0.0.1:"
    assert bytes =~ "content-length: 7\r\n"
    assert String.ends_with?(bytes, "\r\n\r\nrequest")
    refute inspect(response) =~ "hello"
  end

  test "ordered headers preserve separate values without comma joining" do
    {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")

    assert {:ok, _} =
             Egress.request(enroll(url), :get, "/", [{"cookie", "a=1"}, {"cookie", "b=2"}], nil)

    assert_receive {:received, bytes}
    assert bytes =~ "cookie: a=1\r\ncookie: b=2\r\n"
    refute bytes =~ "a=1, b=2"
  end

  test "read-to-close framing awaits body bytes after an initially empty buffer" do
    {url, peer} =
      server(send: "HTTP/1.1 200 OK\r\nconnection: close\r\n\r\n", await: :body, send: "body")

    callback = fn
      {:headers, _}, acc ->
        send(peer, :body)
        {:cont, acc}

      {:data, bytes}, acc ->
        {:cont, acc <> bytes}

      _, acc ->
        {:cont, acc}
    end

    assert {:ok, %Response{body: nil, acc: "body", completion: :complete}} =
             Egress.stream(enroll(url), :get, "/", %{}, nil, callback, "")
  end

  test "HEAD, 204 and informational responses do not wait for absent bodies" do
    for {method, status} <- [{:head, 200}, {:get, 204}] do
      {url, _} =
        server(
          send:
            "HTTP/1.1 103 Early Hints\r\nlink: </x>\r\n\r\n" <>
              "HTTP/1.1 #{status} OK\r\ncontent-length: 9999\r\n\r\n",
          wait_closed: true
        )

      assert {:ok, %Response{body: "", completion: :complete}} =
               Egress.request(enroll(url), method, "/", %{}, nil)

      assert_receive {:peer_closed, :closed}, 1_000
    end
  end

  test "every 3xx is refused with its status, without following either origin" do
    {target, _} = server([])

    for location <- [target, "/same-origin"], status <- [300, 302, 304, 399] do
      {url, _} = server(send: "HTTP/1.1 #{status} Redirect\r\nlocation: #{location}\r\n\r\n")

      assert {:error, %Error{reason: :redirect_refused, status: ^status, sent: :possible}} =
               Egress.request(enroll(url), :get, "/", %{}, nil)

      assert_receive {:received, _}
    end

    refute_receive {:received, _}, 30
    {url, _} = server(send: "HTTP/1.1 101 Switching Protocols\r\n\r\n")

    assert {:error, %Error{reason: :unsupported_upgrade, status: 101, sent: :possible}} =
             Egress.request(enroll(url), :get, "/", %{}, nil)
  end

  test "buffered body overflow errors unless capped capture is explicitly requested" do
    for opts <- [[], [capture_limit: true]] do
      {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nabcdef")
      result = Egress.request(enroll(url), :get, "/", %{}, nil, [max_body_bytes: 3] ++ opts)

      if opts == [] do
        assert {:error,
                %Error{reason: :body_too_large, phase: :body, sent: :possible, status: 200}} =
                 result
      else
        assert {:ok, %Response{body: "abc", completion: :capture_limit}} = result
      end
    end

    {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\nabc")

    assert {:ok, %Response{completion: :complete, body: "abc"}} =
             Egress.request(enroll(url), :get, "/", %{}, nil, max_body_bytes: 3)

    oversized = String.duplicate("x", 70_000)
    {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 70000\r\n\r\n" <> oversized)

    assert {:error, %Error{reason: :body_too_large}} =
             Egress.request(enroll(url), :get, "/", %{}, nil)
  end

  test "stream body caps and malformed heads produce classified outcomes" do
    for opts <- [[max_body_bytes: 3], [max_body_bytes: 3, capture_limit: true]] do
      {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 6\r\n\r\nabcdef")

      callback = fn
        {:data, bytes}, acc -> {:cont, acc <> bytes}
        _, acc -> {:cont, acc}
      end

      result = Egress.stream(enroll(url), :get, "/", %{}, nil, callback, "", opts)

      if opts[:capture_limit] do
        assert {:ok, %Response{completion: :capture_limit, acc: "abc"}} = result
      else
        assert {:error, %Error{reason: :body_too_large, sent: :possible}} = result
      end
    end

    {url, _} = server(send: "HTTP/1.1 nope\r\n\r\n")

    assert {:error, %Error{reason: :malformed_status_line, phase: :head}} =
             Egress.request(enroll(url), :get, "/", %{}, nil)
  end

  test "zero-byte captures close after headers through delivery and egress" do
    for adapter <- [:bounded, :egress] do
      {url, _} =
        server(send: "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n", wait_closed: true)

      result =
        case adapter do
          :bounded ->
            Bounded.request(:get, url, %{}, nil,
              validate_destination: false,
              max_body_bytes: 0
            )

          :egress ->
            Egress.request(enroll(url), :get, "/", %{}, nil,
              max_body_bytes: 0,
              capture_limit: true
            )
        end

      assert {:ok, %{body: ""}} = result
      assert_receive {:peer_closed, :closed}, 1_000
    end
  end

  test "SSE bytes survive split chunk data and streams have no default body cap" do
    first = "data: {\"a\":"
    second = "1}\n\n" <> String.duplicate("x", 70_000)

    {url, _} =
      server(
        send:
          "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n" <>
            Integer.to_string(byte_size(first), 16) <> "\r\n" <> first,
        pause: 20,
        send:
          "\r\n" <>
            Integer.to_string(byte_size(second), 16) <>
            "\r\n" <>
            second <>
            "\r\n0\r\n\r\n"
      )

    callback = fn event, acc -> {:cont, [event | acc]} end

    assert {:ok, %Response{body: nil, completion: :complete, acc: events}} =
             Egress.stream(enroll(url), :get, "/", %{}, nil, callback, [])

    events = Enum.reverse(events)
    assert [{:status, 200}, {:headers, _} | _] = events
    assert IO.iodata_to_binary(for {:data, bytes} <- events, do: bytes) == first <> second
  end

  test "halt and every callback failure close the socket and discard raised values" do
    for failure <- [:halt, :raise, :throw, :exit, :invalid] do
      {url, _} =
        server(send: "HTTP/1.1 200 OK\r\ncontent-length: 20\r\n\r\nabc", wait_closed: true)

      callback = fn
        {:data, _}, acc ->
          case failure do
            :halt -> {:halt, acc + 1}
            :raise -> raise "callback-sentinel"
            :throw -> throw({:sensitive, "callback-sentinel"})
            :exit -> exit("callback-sentinel")
            :invalid -> :not_a_result
          end

        _, acc ->
          {:cont, acc}
      end

      result = Egress.stream(enroll(url), :get, "/", %{}, nil, callback, 0)

      if failure == :halt do
        assert {:ok, %Response{completion: :halted, acc: 1}} = result
      else
        assert {:error, %Error{reason: :callback_failed, phase: :body, sent: :possible}} = result
        refute inspect(result) =~ "callback-sentinel"
      end

      assert_receive {:peer_closed, :closed}, 1_000
    end
  end

  test "callbacks can halt on status or headers, and their time counts toward total deadline" do
    for event_type <- [:status, :headers] do
      {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 99\r\n\r\n", wait_closed: true)

      callback = fn {type, _}, acc ->
        if type == event_type, do: {:halt, :stopped}, else: {:cont, acc}
      end

      assert {:ok, %Response{completion: :halted, acc: :stopped}} =
               Egress.stream(enroll(url), :get, "/", %{}, nil, callback, nil)

      assert_receive {:peer_closed, :closed}, 1_000
    end

    {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 0\r\n\r\n")

    callback = fn _, acc ->
      :timer.sleep(100)
      {:cont, acc}
    end

    assert {:error, %Error{reason: :deadline_exceeded, sent: :possible}} =
             Egress.stream(enroll(url), :get, "/", %{}, nil, callback, nil, timeout: 40)
  end

  test "connect failure is unsent, head/body close or reset is possibly sent" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    :gen_tcp.close(listener)
    url = "http://127.0.0.1:#{port}"

    assert {:error, %Error{reason: :connect_failed, phase: :connect, sent: :none}} =
             Egress.request(enroll(url), :get, "/", %{}, nil)

    for {bytes, reason, phase} <- [
          {"HTTP/1.1 200 OK\r\n", :truncated_response, :head},
          {"HTTP/1.1 200 OK\r\ncontent-length: 10\r\n\r\nabc", :truncated_body, :body},
          {"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n5\r\nabc", :truncated_body,
           :body}
        ] do
      {url, _} = server(send: bytes)

      assert {:error, %Error{reason: ^reason, phase: ^phase, sent: :possible}} =
               Egress.request(enroll(url), :get, "/", %{}, nil)
    end

    {url, _} = server(reset: true)

    assert {:error, %Error{sent: :possible, reason: :transport_failed}} =
             Egress.request(enroll(url), :get, "/", %{}, nil)
  end

  test "idle, total and pre-I/O deadlines are classified independently" do
    {url, _} = server(pause: 200)

    assert {:error, %Error{reason: :idle_timeout, phase: :head, sent: :possible}} =
             Egress.request(enroll(url), :get, "/", %{}, nil, idle_timeout: 40)

    {url, _} =
      server(
        send: "HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\na",
        pause: 50,
        send: "b",
        pause: 150,
        send: "c"
      )

    assert {:error, %Error{reason: :deadline_exceeded, phase: :body, sent: :possible}} =
             Egress.request(enroll(url), :get, "/", %{}, nil, timeout: 100, idle_timeout: 300)

    assert {:error, %Error{reason: :deadline_exceeded, sent: :none}} =
             Egress.request(enroll(url), :get, "/", %{}, nil, timeout: 0)

    {:ok, destination} = Egress.destination("https://example.com/")

    assert {:error, %Error{reason: :deadline_exceeded, phase: :resolve, sent: :none}} =
             Egress.request(destination, :get, "/", %{}, nil, timeout: 0)

    assert {:error, %Error{reason: :deadline_exceeded, sent: :none}} =
             Egress.request(enroll(url), :get, "/", %{}, nil, connect_timeout: 0)
  end

  test "caller death closes the calling process's socket" do
    {url, _} = server(send: "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n", wait_closed: true)
    parent = self()

    caller =
      spawn(fn ->
        Egress.stream(
          enroll(url),
          :get,
          "/",
          %{},
          nil,
          fn event, acc ->
            send(parent, {:callback, event})
            {:cont, acc}
          end,
          nil
        )
      end)

    assert_receive {:callback, {:headers, _}}, 1_000
    Process.exit(caller, :kill)
    assert_receive {:peer_closed, :closed}, 1_000
  end

  test "all egress telemetry fields are closed and sentinel-free" do
    handler = "egress-sentinel-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach_many(
        handler,
        EgressEvents.all(),
        fn name, measurements, metadata, pid ->
          send(pid, {:event, name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    sentinel = "egress-private-sentinel"

    {url, _} =
      server(
        send:
          "HTTP/1.1 200 OK\r\nx-private: #{sentinel}\r\ncontent-length: #{byte_size(sentinel)}\r\n\r\n#{sentinel}"
      )

    destination = enroll(url <> "/#{sentinel}", destination_id: "opaque")

    assert {:ok, _} =
             Egress.request(
               destination,
               :post,
               url <> "/#{sentinel}?q=#{sentinel}",
               %{"x-private" => sentinel},
               sentinel
             )

    assert_receive {:event, [:ash_hooks, :egress, :start], start, start_meta}
    assert_receive {:event, [:ash_hooks, :egress, :stop], stop, meta}
    assert start.bytes_sent == 0
    assert start_meta.sent == :none
    assert stop.bytes_sent > byte_size(sentinel)
    assert stop.bytes_received > byte_size(sentinel)
    assert meta.sent == :possible
    assert meta.completion == :complete
    assert meta.destination_id == "opaque"
    assert meta.address_family == :inet
    assert meta.method == "POST"

    assert Enum.sort(Map.keys(meta)) ==
             Enum.sort(
               ~w(destination_id scheme port address_family method phase sent status completion reason)a
             )

    assert Enum.sort(Map.keys(stop)) ==
             Enum.sort(
               ~w(dns_duration_ms connect_duration_ms tls_duration_ms first_byte_duration_ms total_duration_ms bytes_sent bytes_received)a
             )

    refute inspect({start, start_meta, stop, meta}) =~ sentinel
    refute_receive {:event, [:finch | _], _, _}, 30
  end

  defp enroll(url, opts \\ []) do
    {:ok, destination} =
      Egress.destination(url, [allow_http: true, validate_destination: false] ++ opts)

    destination
  end

  defp server(actions) do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    pid = spawn(fn -> accept(listener, actions, parent) end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(pid, :kill)
    end)

    {"http://127.0.0.1:#{port}", pid}
  end

  defp accept(listener, actions, parent) do
    case :gen_tcp.accept(listener, 5_000) do
      {:ok, socket} -> serve(socket, actions, parent)
      _ -> :ok
    end
  end

  defp serve(socket, actions, parent) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> send(parent, {:received, bytes})
      _ -> :ok
    end

    Enum.each(actions, fn
      {:send, bytes} ->
        :gen_tcp.send(socket, bytes)

      {:pause, ms} ->
        :timer.sleep(ms)

      {:await, message} ->
        receive do
          ^message -> :ok
        end

      {:wait_closed, true} ->
        send(parent, {:peer_closed, elem(:gen_tcp.recv(socket, 0, 2_000), 1)})

      {:reset, true} ->
        :inet.setopts(socket, linger: {true, 0})
    end)

    :gen_tcp.close(socket)
  end
end
