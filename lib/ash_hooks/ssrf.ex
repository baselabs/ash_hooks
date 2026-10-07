defmodule AshHooks.Ssrf do
  @moduledoc """
  Destination validation for outbound webhooks.

  Endpoint registration uses `registration_safe?/1`: it checks the HTTP(S)
  scheme, known metadata hostnames, and literal IP addresses without DNS.
  Hostname resolution happens at send time, so registration does not depend
  on the destination's current DNS availability.

  `safe_url?/1` and `resolve_public/2` resolve IPv4 and IPv6 addresses and
  require a nonempty result containing only public addresses. Private,
  loopback, link-local, unique-local, shared, and reserved ranges are rejected.
  IPv4-mapped and IPv4-compatible IPv6 addresses are classified using their
  embedded IPv4 address.

  DNS resolution has a two-second ceiling, shortened by a supplied operation
  deadline. Both supplied HTTP adapters connect to an address from the
  validated result while retaining the original hostname for TLS and HTTP.
  """

  @resolve_timeout_ms 2_000

  @metadata_hostnames ~w(metadata.google.internal metadata.goog)

  @doc """
  True when `url` is an http(s) URL whose host is not metadata and whose
  resolved addresses are all public.
  """
  @spec safe_url?(term()) :: boolean()
  def safe_url?(url) when is_binary(url) do
    case URI.new(url) do
      # URI.new (RFC 3986 parser) carries the scheme as a BINARY, not an atom
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] ->
        host = host && String.downcase(host)

        cond do
          host in [nil, ""] -> false
          host in @metadata_hostnames -> false
          true -> host_public?(uri, host)
        end

      _other ->
        false
    end
  end

  def safe_url?(_other), do: false

  @doc """
  Returns validated addresses behind a URL for connection pinning:
  `{:ok, %{uri: URI, addresses: [ip]}}` when every resolved address is
  public, `{:error, :unsafe | :unresolvable}` otherwise. The connection
  target must come from this same result to prevent DNS rebinding between
  validation and connection.
  """
  @spec resolve_public(term()) ::
          {:ok, %{uri: URI.t(), addresses: [:inet.ip_address()]}} | {:error, atom()}
  def resolve_public(url, opts \\ [])

  def resolve_public(url, opts) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] ->
        check_host(uri, host && String.downcase(host), opts)

      _other ->
        {:error, :unsafe}
    end
  end

  def resolve_public(_other, _opts), do: {:error, :unsafe}

  defp check_host(_uri, host, _opts) when host in [nil, ""], do: {:error, :unsafe}
  defp check_host(_uri, host, _opts) when host in @metadata_hostnames, do: {:error, :unsafe}

  defp check_host(uri, host, opts) do
    case resolve(uri, host, opts) do
      {:ok, addresses} ->
        if Enum.all?(addresses, &public_address?/1),
          do: {:ok, %{uri: uri, addresses: addresses}},
          else: {:error, :unsafe}

      :error ->
        {:error, :unresolvable}
    end
  end

  @doc """
  Checks the scheme, metadata hostnames, and literal IP addresses at
  registration. This check does not resolve hostnames.
  """
  @spec registration_safe?(term()) :: boolean()
  def registration_safe?(url) when is_binary(url) do
    case URI.new(url) do
      # URI.new (RFC 3986 parser) carries the scheme as a BINARY
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        host = host && String.downcase(host)

        cond do
          host in [nil, ""] -> false
          host in @metadata_hostnames -> false
          true -> literal_host_public?(host)
        end

      _other ->
        false
    end
  end

  def registration_safe?(_other), do: false

  defp literal_host_public?(host) do
    case :inet.parse_address(String.to_charlist(host_without_brackets(host))) do
      {:ok, address} -> public_address?(address)
      {:error, _} -> true
    end
  end

  defp host_public?(uri, host) do
    case resolve(uri, host, []) do
      {:ok, addresses} -> Enum.all?(addresses, &public_address?/1)
      :error -> false
    end
  end

  # Literal IP hosts skip DNS; hostnames resolve — BOTH families, because
  # ANY answer class can carry the private address that must reject.
  defp resolve(uri, host, opts) do
    bare = host_without_brackets(host)

    case :inet.parse_address(String.to_charlist(bare)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        case resolved_addresses(uri, String.to_charlist(bare), opts) do
          [] -> :error
          addresses -> {:ok, addresses}
        end
    end
  end

  # uri.host arrives bracketless — URI.new strips IPv6 brackets
  defp host_without_brackets(host), do: host

  defp resolved_addresses(_uri, charlist, opts) do
    now = System.monotonic_time(:millisecond)
    deadline = min(opts[:deadline] || now + @resolve_timeout_ms, now + @resolve_timeout_ms)

    # Query both families under one deadline. A family that returns no
    # addresses contributes nothing; the combined result must be nonempty,
    # and adapters connect only to an address validated from that result.
    bounded_resolve(charlist, :inet, deadline) ++ bounded_resolve(charlist, :inet6, deadline)
  end

  # Bound send-time resolution by the shared DNS and operation deadlines.
  defp bounded_resolve(charlist, family, deadline) do
    task = Task.async(fn -> :inet.gethostbyname(charlist, family) end)
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, {:hostent, _, _, _, _, addresses}}} -> addresses
      _failed_or_timeout -> []
    end
  end

  defp public_address?(address) do
    case normalize(address) do
      {a, b, c, d} -> ipv4_public?(a, b, c, d)
      _v6 -> ipv6_public?(address)
    end
  end

  # ::ffff:a.b.c.d and the ipv4-compat ::a.b.c.d both reduce to their v4.
  defp normalize({0, 0, 0, 0, 0, hi, _, _} = address) when hi in [0, 65_535],
    do: embedded_v4(address)

  defp normalize(address) when tuple_size(address) == 4, do: address
  defp normalize(address) when tuple_size(address) == 8, do: address

  import Bitwise

  defp embedded_v4({_a, _b, _c, _d, _e, _f, hi, lo}) do
    {band(hi, 0xFF00) >>> 8, band(hi, 0x00FF), band(lo, 0xFF00) >>> 8, band(lo, 0x00FF)}
  end

  defp ipv4_public?(10, _, _, _), do: false
  defp ipv4_public?(172, b, _, _) when b in 16..31, do: false
  defp ipv4_public?(192, 168, _, _), do: false
  defp ipv4_public?(127, _, _, _), do: false
  defp ipv4_public?(169, 254, _, _), do: false
  defp ipv4_public?(100, b, _, _) when b in 64..127, do: false
  defp ipv4_public?(0, _, _, _), do: false
  # IETF protocol assignments: only PCP and TURN anycast are globally reachable.
  defp ipv4_public?(192, 0, 0, d) when d in [9, 10], do: true
  defp ipv4_public?(192, 0, 0, _), do: false
  # documentation ranges (TEST-NET-1/2/3) — reserved, never a real destination
  defp ipv4_public?(192, 0, 2, _), do: false
  defp ipv4_public?(192, 88, 99, _), do: false
  defp ipv4_public?(198, 51, 100, _), do: false
  defp ipv4_public?(198, b, _, _) when b in 18..19, do: false
  defp ipv4_public?(203, 0, 113, _), do: false
  defp ipv4_public?(a, _, _, _) when a in 224..255, do: false
  defp ipv4_public?(_, _, _, _), do: true

  # Prefix masks per RFC 4291/4193, not single-range checks: fc00::/7
  # covers fc00–fdff, fe80::/10 covers fe80–febf, ff00::/8 covers
  # ff00–ffff — naive /16 checks would let fc00::, fe90:: and ff02::
  # through.
  # ::1 is handled by the embedded-v4 reduction below (hi == 0). ULA fc00::/7
  # Globally reachable exceptions within IETF's otherwise non-global 2001::/23.
  defp ipv6_public?({0x2001, 1, 0, 0, 0, 0, 0, last}) when last in [1, 2, 3], do: true
  defp ipv6_public?({0x2001, 3, _, _, _, _, _, _}), do: true
  defp ipv6_public?({0x2001, 4, 0x0112, _, _, _, _, _}), do: true
  defp ipv6_public?({0x2001, second, _, _, _, _, _, _}) when second in 0x20..0x2F, do: true
  defp ipv6_public?({0x2001, second, _, _, _, _, _, _}) when second in 0x30..0x3F, do: true
  # IPv4/IPv6 translation's local-use prefix.
  defp ipv6_public?({0x0064, 0xFF9B, 1, _, _, _, _, _}), do: false
  # Discard-only and dummy prefixes.
  defp ipv6_public?({0x0100, 0, 0, fourth, _, _, _, _}) when fourth in [0, 1], do: false
  # IETF protocol assignments are non-global except the exact exceptions above.
  defp ipv6_public?({0x2001, second, _, _, _, _, _, _}) when band(second, 0xFE00) == 0,
    do: false

  # Documentation, SRv6 SIDs, and deprecated site-local ranges.
  defp ipv6_public?({0x2001, 0x0DB8, _, _, _, _, _, _}), do: false
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFFF0) == 0x3FF0, do: false
  defp ipv6_public?({0x5F00, _, _, _, _, _, _, _}), do: false
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFE00) == 0xFC00, do: false
  # link-local fe80::/10
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: false
  # deprecated site-local fec0::/10
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFEC0, do: false
  # multicast ff00::/8
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFF00) == 0xFF00, do: false
  # transition forms embedding a (possibly private) IPv4: 6to4
  # 2002::/16 and Teredo 2001:0::/32 are refused outright; NAT64
  # 64:ff9b::/96 unwraps its embedded v4
  defp ipv6_public?({0x2002, _, _, _, _, _, _, _}), do: false

  defp ipv6_public?({0x0064, 0xFF9B, 0, 0, 0, 0, hi, lo}),
    do:
      ipv4_public?(
        band(hi, 0xFF00) >>> 8,
        band(hi, 0x00FF),
        band(lo, 0xFF00) >>> 8,
        band(lo, 0x00FF)
      )

  defp ipv6_public?(_), do: true
end
