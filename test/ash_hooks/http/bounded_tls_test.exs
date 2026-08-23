defmodule AshHooks.Http.BoundedTlsTest do
  @moduledoc """
  The bounded adapter's TLS leg over a LIVE CA-verified session: the
  committed local-CA fixtures (test/fixtures/tls — throwaway localhost-only
  material, never trusted anywhere) and the injectable `:cacerts` seam on
  `Target.ssl_options/2` (default unchanged: the OS trust store; D3).

  The literal-IP destination requires the peer cert to carry the IP in its
  iPAddress SAN (chain validation alone would let ANY publicly-trusted
  cert authenticate the peer); the named-host leg exercises SNI + the
  RFC 6125 hostname check.
  """

  use ExUnit.Case, async: false

  alias AshHooks.Http.Bounded

  @dir "test/fixtures/tls"

  defp ca_der do
    [{:Certificate, der, :not_encrypted}] =
      :public_key.pem_decode(File.read!(Path.join(@dir, "local-ca.pem")))

    der
  end

  # one TLS connection: accept, read the request, serve a small JSON body
  defp tls_server(cert) do
    parent = self()

    {:ok, listen} =
      :ssl.listen(0,
        certfile: String.to_charlist(Path.join(@dir, cert)),
        keyfile: String.to_charlist(Path.join(@dir, "server.key")),
        ip: {127, 0, 0, 1},
        active: false,
        mode: :binary
      )

    {:ok, {_addr, port}} = :ssl.sockname(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.transport_accept(listen, 10_000)
      {:ok, socket} = :ssl.handshake(socket, 10_000)
      {:ok, _request} = :ssl.recv(socket, 0, 5_000)
      :ssl.send(socket, "HTTP/1.1 200 OK\r\ncontent-length: 13\r\n\r\n" <> ~s({"tls": true}))
      :timer.sleep(100)
      :ssl.close(socket)
      :ssl.close(listen)
      send(parent, :served)
    end)

    {listen, port}
  end

  defp opts, do: [validate_destination: false, cacerts: [ca_der()], timeout: 5_000]

  test "a named-host https roundtrip completes over the local CA (SNI + RFC 6125)" do
    {_listen, port} = tls_server("server-both-san.pem")

    assert {:ok, %{status: 200, body: body}} =
             Bounded.request(:get, "https://localhost:#{port}/hook", %{}, nil, opts())

    assert body == ~s({"tls": true})
  end

  test "a literal-IP https roundtrip completes via the iPAddress SAN" do
    {_listen, port} = tls_server("server-both-san.pem")

    assert {:ok, %{status: 200, body: body}} =
             Bounded.request(:get, "https://127.0.0.1:#{port}/hook", %{}, nil, opts())

    assert body == ~s({"tls": true})
  end

  test "a chain-valid cert WITHOUT the IP SAN fails closed on a literal destination" do
    {_listen, port} = tls_server("server-dns-only.pem")

    assert {:error, :cert_ip_mismatch} =
             Bounded.request(:get, "https://127.0.0.1:#{port}/hook", %{}, nil, opts())
  end

  test "a TLS peer that dies under an in-flight send is an error tuple, never a raise" do
    parent = self()

    {:ok, listen} =
      :ssl.listen(0,
        certfile: String.to_charlist(Path.join(@dir, "server-both-san.pem")),
        keyfile: String.to_charlist(Path.join(@dir, "server.key")),
        ip: {127, 0, 0, 1},
        active: false,
        mode: :binary
      )

    {:ok, {_addr, port}} = :ssl.sockname(listen)

    spawn(fn ->
      {:ok, socket} = :ssl.transport_accept(listen, 10_000)
      {:ok, socket} = :ssl.handshake(socket, 10_000)
      # same anti-buffering cap as the TCP twin: the receive window pinned
      # to 1KB defeats sysctl autotuning, so the client's 16MB send is
      # provably still in flight when the session dies
      :ssl.setopts(socket, rcvbuf: 1024)
      {:ok, _prefix} = :ssl.recv(socket, 100, 5_000)
      :timer.sleep(100)
      :ssl.close(socket)
      :ssl.close(listen)
      send(parent, :dead)
    end)

    big_body = String.duplicate("z", 16_000_000)

    assert {:error, shape} =
             Bounded.request(
               :post,
               "https://127.0.0.1:#{port}/sink",
               %{},
               big_body,
               Keyword.put(opts(), :connect_timeout, 1_000)
             )

    # the driver-semantics note in Bounded.send_request: the send failure
    # the driver cannot report surfaces at the read
    assert shape in [:truncated_response, :closed] or
             (is_tuple(shape) and elem(shape, 0) == :tls_alert)
  end

  test "the default trust store is unchanged — no local CA injection, no session" do
    {_listen, port} = tls_server("server-both-san.pem")

    assert {:error, _reason} =
             Bounded.request(:get, "https://localhost:#{port}/hook", %{}, nil,
               validate_destination: false,
               timeout: 5_000
             )
  end
end
