defmodule AshHooks.Http.Target do
  @moduledoc false
  # The shared pinning substrate both HTTP adapters consume: resolve the
  # hostname ONCE through Ssrf (every answer public), and connect to the
  # VALIDATED address — TLS names the ORIGINAL host (SNI + RFC 6125
  # check), the host header carries the original host:port. This is what
  # closes the DNS-rebinding TOCTOU: validation and connection share one
  # resolution (derisk-1).

  @spec resolve(String.t(), keyword()) ::
          {:ok,
           %{
             uri: URI.t(),
             address: :inet.ip_address(),
             host: String.t(),
             port: :inet.port_number()
           }}
          | {:error, atom()}
  def resolve(url, opts) do
    resolver =
      if opts[:validate_destination] == false,
        do: &bypass/1,
        else: &AshHooks.Ssrf.resolve_public/1

    case resolver.(url) do
      {:ok, %{uri: uri, addresses: [address | _]}} ->
        host = String.downcase(uri.host)

        {:ok,
         %{uri: uri, address: address, host: host, port: uri.port || default_port(uri.scheme)}}

      {:error, :unsafe} ->
        {:error, :unsafe_destination}

      {:error, :unresolvable} ->
        {:error, :unresolved_host}
    end
  end

  # Test seam ONLY (loopback listeners): the SSRF obligation lives in the
  # driver's send-time check; adapter resolution is defense-in-depth.
  defp bypass(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        case lookup(host) do
          {:ok, address} -> {:ok, %{uri: uri, addresses: [address]}}
          {:error, _} -> {:error, :unresolvable}
        end

      _other ->
        {:error, :unsafe}
    end
  end

  defp lookup(host) do
    # uri.host arrives bracketless — URI.new strips IPv6 brackets — so no
    # unwrapping happens here
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, literal} -> {:ok, literal}
      {:error, _} -> :inet.getaddr(String.to_charlist(host), :inet)
    end
  end

  @spec default_port(String.t()) :: :inet.port_number()
  def default_port("https"), do: 443
  def default_port(_http), do: 80

  @spec host_header(String.t(), :inet.port_number(), String.t()) :: String.t()
  def host_header(host, 443, "https"), do: host
  def host_header(host, 80, "http"), do: host

  def host_header(host, port, _) do
    if String.contains?(host, ":"), do: "[#{host}]:#{port}", else: "#{host}:#{port}"
  end

  # TLS names the ORIGINAL host; a literal-IP destination has no name to
  # verify (SNI disabled, chain validation kept).
  #
  # `cacerts/1` is the injectable trust-store seam (D3, 2026-08-22): the
  # default is UNCHANGED — the OTP CA store — but a caller (adapter opts
  # `[cacerts: der_list]`, threaded from the worker's `:http_opts`) can pin
  # a private CA bundle, which is also how the test suite drives CA-verified
  # loopback sessions against committed local fixtures.
  @spec ssl_options(String.t(), list() | nil) :: keyword()
  def ssl_options(host, cacerts \\ nil) do
    base = [verify: :verify_peer, cacerts: cacerts || :public_key.cacerts_get(), depth: 3]

    if ip_literal?(host) do
      Keyword.put(base, :server_name_indication, :disable)
    else
      Keyword.merge(base,
        server_name_indication: String.to_charlist(host),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      )
    end
  end

  @spec ip_literal?(String.t()) :: boolean()
  def ip_literal?(host) do
    bare = host |> String.replace("[", "") |> String.replace("]", "")
    match?({:ok, _}, :inet.parse_address(String.to_charlist(bare)))
  end
end
