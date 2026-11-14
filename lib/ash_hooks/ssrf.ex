defmodule AshHooks.Ssrf do
  @moduledoc """
  Destination validation for outbound webhooks.

  Endpoint registration uses `registration_safe?/1`: it checks the HTTP(S)
  scheme, known metadata hostnames, and literal IP addresses without DNS.
  Hostname resolution happens at send time, so registration does not depend
  on the destination's current DNS availability.

  `resolve_host_public/2`, `safe_url?/1`, and `resolve_public/2` resolve IPv4
  and IPv6 addresses and require a nonempty result containing only public
  addresses. Private, loopback, link-local, unique-local, shared, and reserved
  ranges are rejected.
  IPv4-mapped and IPv4-compatible IPv6 addresses are classified using their
  embedded IPv4 address, as does the NAT64 `64:ff9b::/96` prefix. Other IPv6
  addresses require an allocated prefix from the IANA IPv6 Global Unicast
  Address Assignments registry, with non-global special-purpose ranges
  refused and their globally reachable exceptions retained. Reserved and
  unallocated space is refused. The allocation table was retrieved on
  November 13, 2026; new allocations require a package update before admission.

  A hostname that fails to resolve fails as `:nxdomain` when every queried
  family returned an authoritative negative answer, and as `:resolve_timeout`
  otherwise (timeout, temporary resolver failure, or mixed evidence), using the
  conservative retryable label. `safe_url?/1` stays boolean: both are
  `false` there.

  DNS resolution has a two-second ceiling, shortened by a supplied operation
  deadline. Both supplied HTTP adapters connect to an address from the
  validated result while retaining the original hostname for TLS and HTTP.

  Callers of `resolve_host_public/2` must resolve at every connect, reconnect,
  redirect, failover, and broker-advertised address. Connect only to an address
  returned by that call, and keep the original name for TLS verification and
  server name indication. Resolving again through another connection API
  would permit DNS rebinding between validation and connection.
  """

  @resolve_timeout_ms 2_000

  @metadata_hostnames ~w(metadata.google.internal metadata.goog)

  # IANA IPv6 Global Unicast Address Assignments, retrieved 2026-11-13.
  # Include ALLOCATED entries only, including IANA's special-purpose parent.
  # More-specific special-purpose rules below take precedence.
  # https://www.iana.org/assignments/ipv6-unicast-address-assignments/ipv6-unicast-address-assignments.xhtml
  # Special-purpose registries checked on the same date:
  # https://www.iana.org/assignments/iana-ipv4-special-registry/
  # https://www.iana.org/assignments/iana-ipv6-special-registry/
  @ipv6_allocations ~w(
    2001::/23
    2001:200::/23
    2001:400::/23
    2001:600::/23
    2001:800::/22
    2001:c00::/23
    2001:e00::/23
    2001:1200::/23
    2001:1400::/22
    2001:1800::/23
    2001:1a00::/23
    2001:1c00::/22
    2001:2000::/19
    2001:4000::/23
    2001:4200::/23
    2001:4400::/23
    2001:4600::/23
    2001:4800::/23
    2001:4a00::/23
    2001:4c00::/23
    2001:5000::/20
    2001:8000::/19
    2001:a000::/20
    2001:b000::/20
    2002::/16
    2003::/18
    2400::/12
    2410::/12
    2600::/12
    2610::/23
    2620::/23
    2630::/12
    2800::/12
    2a00::/12
    2a10::/12
    2c00::/12
  )

  @doc """
  Resolves a host to a nonempty list containing only public IP addresses.

  Accepts a DNS name with IDNA-encoded ASCII labels (letters, digits,
  underscores, and inner hyphens) and at most one trailing dot, a bare IPv4 literal, or a bare or bracketed IPv6 literal. Malformed
  brackets, zone identifiers, ports, schemes, paths, credentials, whitespace,
  control characters, empty labels, and other malformed hosts return
  `{:error, :invalid_host}` without raising.

  Returns `{:ok, [ip_address]}` only when every resolved address is public.
  A non-public answer or known metadata hostname returns `{:error, :unsafe}`.
  Resolution failures return `{:error, :nxdomain | :resolve_timeout}`.
  There is no destination-policy bypass.

  DNS resolution has a two-second ceiling. The optional `:deadline` is an
  absolute `System.monotonic_time(:millisecond)` value that can shorten it.

  Resolve at every connect, reconnect, redirect, failover, and broker-advertised
  address. Connect only to a returned address and retain the original name for
  TLS verification and server name indication.
  """
  @spec resolve_host_public(term(), keyword()) ::
          {:ok, [:inet.ip_address()]}
          | {:error, :unsafe | :nxdomain | :resolve_timeout | :invalid_host}
  def resolve_host_public(host, opts \\ []) do
    with {:ok, parsed} <- parse_host(host),
         {:ok, addresses} <- resolve_host(parsed, opts) do
      if Enum.all?(addresses, &public_address?/1),
        do: {:ok, addresses},
        else: {:error, :unsafe}
    end
  end

  @doc """
  True when `url` is an http(s) URL whose host is not metadata and whose
  resolved addresses are all public.
  """
  @spec safe_url?(term()) :: boolean()
  def safe_url?(url) when is_binary(url) do
    case URI.new(url) do
      # URI.new (RFC 3986 parser) carries the scheme as a BINARY, not an atom
      {:ok, %URI{scheme: scheme, host: host}} when scheme in ["http", "https"] ->
        host = host && String.downcase(host)

        cond do
          host in [nil, ""] -> false
          host in @metadata_hostnames -> false
          true -> host_public?(host)
        end

      _other ->
        false
    end
  end

  def safe_url?(_other), do: false

  @doc """
  Returns validated addresses behind a URL for connection pinning:
  `{:ok, %{uri: URI, addresses: [ip]}}` when every resolved address is
  public, `{:error, :unsafe}` when an answer is non-public, and
  `{:error, :nxdomain | :resolve_timeout}` when the name does not resolve.
  The connection target must come from this same result to prevent DNS
  rebinding between validation and connection.
  """
  @spec resolve_public(term(), keyword()) ::
          {:ok, %{uri: URI.t(), addresses: [:inet.ip_address()]}} | {:error, atom()}
  def resolve_public(url, opts \\ [])

  def resolve_public(url, opts) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] ->
        case resolve_host_public(host, opts) do
          {:ok, addresses} -> {:ok, %{uri: uri, addresses: addresses}}
          {:error, :invalid_host} -> {:error, :unsafe}
          {:error, reason} -> {:error, reason}
        end

      _other ->
        {:error, :unsafe}
    end
  end

  def resolve_public(_other, _opts), do: {:error, :unsafe}

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
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, address} -> public_address?(address)
      {:error, _} -> true
    end
  end

  defp host_public?(host) do
    case resolve_host_public(host) do
      {:ok, _addresses} -> true
      {:error, _dns_error} -> false
    end
  end

  defp parse_host(host) when is_binary(host) and byte_size(host) in 1..254 do
    # Validate bytes before conversion so invalid UTF-8 and all controls are
    # refused without raising. The only bracketed input is an IPv6 literal.
    if Regex.match?(~r/\A[a-zA-Z0-9_.:\[\]-]+\z/, host) do
      parse_host_address(host)
    else
      {:error, :invalid_host}
    end
  end

  defp parse_host(_other), do: {:error, :invalid_host}

  defp parse_host_address("[" <> rest) do
    case String.split(rest, "]") do
      [bare, ""] -> parse_ipv6(bare)
      _malformed -> {:error, :invalid_host}
    end
  end

  defp parse_host_address(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} -> {:ok, address}
      {:error, _} -> parse_dns_name(host)
    end
  end

  defp parse_ipv6(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, address} when tuple_size(address) == 8 -> {:ok, address}
      _malformed -> {:error, :invalid_host}
    end
  end

  defp parse_dns_name(host) do
    name = host |> String.downcase() |> String.replace_suffix(".", "")

    if byte_size(name) <= 253 and
         Enum.all?(String.split(name, "."), &valid_dns_label?/1) do
      {:ok, {name, host}}
    else
      {:error, :invalid_host}
    end
  end

  # DNS carries underscore labels (service names, some provider hosts), and
  # URL hosts with them resolved before this check existed. Safety comes from
  # classifying every resolved address, not from the label alphabet.
  defp valid_dns_label?(label) do
    byte_size(label) in 1..63 and
      Regex.match?(~r/\A[a-zA-Z0-9_](?:[a-zA-Z0-9_-]*[a-zA-Z0-9_])?\z/, label)
  end

  defp resolve_host({name, _host}, _opts) when name in @metadata_hostnames,
    do: {:error, :unsafe}

  defp resolve_host({_name, host}, opts),
    do: resolve_hostname(String.to_charlist(host), opts)

  defp resolve_host(address, _opts), do: {:ok, [address]}

  defp resolve_hostname(charlist, opts) do
    now = System.monotonic_time(:millisecond)
    deadline = min(opts[:deadline] || now + @resolve_timeout_ms, now + @resolve_timeout_ms)

    # Query both families under one deadline. A family that returns no
    # addresses contributes nothing; the combined result must be nonempty,
    # and adapters connect only to an address validated from that result.
    [bounded_resolve(charlist, :inet, deadline), bounded_resolve(charlist, :inet6, deadline)]
    |> combine_family_results()
  end

  @doc false
  # Pure classification of the per-family resolution outcomes — public only
  # as the deterministic test seam for the failure vocabulary (the live
  # resolver's answer is environment-dependent). nxdomain requires EVERY
  # family to have answered authoritatively negative; anything else —
  # timeout, temporary failure, mixed evidence — is the conservative
  # retryable label.
  @spec combine_family_results([
          {:ok, [:inet.ip_address()]}
          | {:error, :nxdomain | :resolve_timeout}
        ]) :: {:ok, [:inet.ip_address()]} | {:error, :nxdomain | :resolve_timeout}
  def combine_family_results(results) do
    addresses = for {:ok, family_addresses} <- results, address <- family_addresses, do: address

    cond do
      addresses != [] -> {:ok, addresses}
      Enum.all?(results, &match?({:error, :nxdomain}, &1)) -> {:error, :nxdomain}
      true -> {:error, :resolve_timeout}
    end
  end

  # Bound send-time resolution by the shared DNS and operation deadlines.
  defp bounded_resolve(charlist, family, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    if timeout == 0 do
      {:error, :resolve_timeout}
    else
      task = Task.async(fn -> :inet.gethostbyname(charlist, family) end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, {:ok, {:hostent, _, _, _, _, addresses}}} -> {:ok, addresses}
        {:ok, {:error, :nxdomain}} -> {:error, :nxdomain}
        _timeout_or_temporary -> {:error, :resolve_timeout}
      end
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

  defp normalize({0x0064, 0xFF9B, 0, 0, 0, 0, _, _} = address), do: embedded_v4(address)

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

  for prefix <- @ipv6_allocations do
    [host, length] = String.split(prefix, "/")
    {:ok, {first, second, _, _, _, _, _, _}} = :inet.parse_address(String.to_charlist(host))
    shift = 32 - String.to_integer(length)
    network = (first <<< 16 ||| second) >>> shift

    defp ipv6_public?({first, second, _, _, _, _, _, _})
         when (first <<< 16 ||| second) >>> unquote(shift) == unquote(network),
         do: true
  end

  defp ipv6_public?(_), do: false
end
