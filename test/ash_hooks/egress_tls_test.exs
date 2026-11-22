defmodule AshHooks.EgressTlsTest do
  use ExUnit.Case, async: false

  alias AshHooks.Egress
  alias AshHooks.Egress.Error
  alias AshHooks.Http.Bounded

  @dir "test/fixtures/tls/"

  test "delivery and egress share one real TLS identity and pin matrix" do
    for adapter <- [:bounded, :egress],
        {certificate, host, trust, pin, expected} <- [
          {"server-both-san.pem", "localhost", :ca, nil, :ok},
          {"server-both-san.pem", "127.0.0.1", :ca, nil, :ok},
          {"server-dns-only.pem", "127.0.0.1", :ca, nil, :cert_ip_mismatch},
          {"server-both-san.pem", "localhost", :system, nil, :tls_failed},
          {"server-wrong-san.pem", "localhost", :ca, nil, :tls_failed},
          {"server-both-san.pem", "localhost", :ca, :matching, :ok},
          {"server-both-san.pem", "localhost", :ca, :mismatch, :certificate_pin_mismatch}
        ] do
      port = tls_server(certificate)
      opts = [validate_destination: false, timeout: 3_000]
      opts = if trust == :ca, do: Keyword.put(opts, :cacerts, [der("local-ca.pem")]), else: opts

      pin =
        case pin do
          :matching -> {:sha256, :crypto.hash(:sha256, der(certificate))}
          :mismatch -> {:sha256, <<0::256>>}
          nil -> nil
        end

      url = "https://#{host}:#{port}/"

      result =
        case adapter do
          :bounded ->
            Bounded.request(:get, url, %{}, nil, Keyword.put(opts, :certificate_pin, pin))

          :egress ->
            {:ok, destination} =
              Egress.destination(url, validate_destination: false, certificate_pin: pin)

            Egress.request(destination, :get, url, %{}, nil, opts)
        end

      case {adapter, expected, result} do
        {_, :ok, {:ok, %{status: 200, body: "ok"}}} ->
          assert_receive {:tls_http, _}, 1_000

        {:egress, reason, {:error, %Error{reason: reason, phase: :tls, sent: :none}}} ->
          refute_receive {:tls_http, _}, 20

        {:bounded, :tls_failed, {:error, _}} ->
          refute_receive {:tls_http, _}, 20

        {:bounded, reason, {:error, reason}} ->
          refute_receive {:tls_http, _}, 20

        other ->
          flunk("TLS identity matrix failed: #{inspect(other)}")
      end
    end
  end

  test "a TCP peer closing before TLS sends no HTTP bytes" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)
    parent = self()

    peer =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        :gen_tcp.close(socket)
        send(parent, :tls_peer_closed)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(peer, :kill)
    end)

    {:ok, destination} =
      Egress.destination("https://127.0.0.1:#{port}/", validate_destination: false)

    assert {:error, %Error{reason: :tls_failed, phase: :tls, sent: :none}} =
             Egress.request(destination, :post, "/", %{}, "never written",
               cacerts: [der("local-ca.pem")]
             )

    assert_receive :tls_peer_closed
  end

  test "TLS handshake time is bounded by the connect budget from call start" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listener)

    peer =
      spawn(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 2_000)
        :gen_tcp.recv(socket, 0, 2_000)
        :timer.sleep(500)
        :gen_tcp.close(socket)
      end)

    on_exit(fn ->
      :gen_tcp.close(listener)
      Process.exit(peer, :kill)
    end)

    {:ok, destination} =
      Egress.destination("https://127.0.0.1:#{port}/", validate_destination: false)

    assert {:error, %Error{reason: :deadline_exceeded, phase: :tls, sent: :none}} =
             Egress.request(destination, :get, "/", %{}, nil,
               cacerts: [der("local-ca.pem")],
               connect_timeout: 40,
               timeout: 1_000
             )
  end

  defp der(file) do
    [{:Certificate, der, :not_encrypted}] = :public_key.pem_decode(File.read!(@dir <> file))
    der
  end

  defp tls_server(certificate) do
    parent = self()

    {:ok, listener} =
      :ssl.listen(0,
        certfile: String.to_charlist(@dir <> certificate),
        keyfile: String.to_charlist(@dir <> "server.key"),
        ip: {127, 0, 0, 1},
        active: false,
        mode: :binary
      )

    {:ok, {_, port}} = :ssl.sockname(listener)

    pid = spawn(fn -> serve_tls(listener, parent) end)

    on_exit(fn ->
      :ssl.close(listener)
      Process.exit(pid, :kill)
    end)

    port
  end

  defp serve_tls(listener, parent) do
    with {:ok, socket} <- :ssl.transport_accept(listener, 5_000),
         {:ok, socket} <- :ssl.handshake(socket, 3_000) do
      case :ssl.recv(socket, 0, 3_000) do
        {:ok, bytes} ->
          send(parent, {:tls_http, bytes})
          :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nok")

        _ ->
          :ok
      end

      :ssl.close(socket)
    end
  end
end
