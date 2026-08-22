defmodule AshHooks.Ssrf do
  @moduledoc """
  The SSRF destination classifier (ADR-0005 — enforced at endpoint
  registration AND again at send time).

  A URL is safe when: the scheme is `http`/`https`, the host is not a
  known cloud-metadata name, and EVERY address the host resolves to is
  public. Any private/loopback/link-local/ULA/CGNAT/reserved answer
  rejects the URL — one rogue A record among the answers is exactly the
  bypass; resolver failure rejects too (fail-closed: an unresolvable
  destination cannot be verified safe).

  IPv4-mapped and IPv4-compatible IPv6 forms (`::ffff:a.b.c.d`, `::a.b.c.d`)
  are normalized to their embedded v4 before classification.
  Registration-time resolution is bounded (`@resolve_timeout_ms`) — an
  offline or slow resolver fails the cast loudly rather than hanging it.

  Residual (documented, by design of the `:httpc` adapter): send-time
  re-resolution narrows but cannot eliminate the DNS-rebinding TOCTOU
  window — full elimination needs connect-time IP pinning the adapter
  cannot express.
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
  The VALIDATED ADDRESSES behind a URL — the adapter's pinning input:
  `{:ok, %{uri: URI, addresses: [ip]}}` when every resolved address is
  public, `{:error, :unsafe | :unresolvable}` otherwise. The connection
  target comes FROM this same resolution, which is what closes the
  rebinding TOCTOU (validate-then-connect-on-the-same-answer).
  """
  @spec resolve_public(term()) ::
          {:ok, %{uri: URI.t(), addresses: [:inet.ip_address()]}} | {:error, atom()}
  def resolve_public(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host} = uri} when scheme in ["http", "https"] ->
        check_host(uri, host && String.downcase(host))

      _other ->
        {:error, :unsafe}
    end
  end

  def resolve_public(_other), do: {:error, :unsafe}

  defp check_host(_uri, host) when host in [nil, ""], do: {:error, :unsafe}
  defp check_host(_uri, host) when host in @metadata_hostnames, do: {:error, :unsafe}

  defp check_host(uri, host) do
    case resolve(uri, host) do
      {:ok, addresses} ->
        if Enum.all?(addresses, &public_address?/1),
          do: {:ok, %{uri: uri, addresses: addresses}},
          else: {:error, :unsafe}

      :error ->
        {:error, :unresolvable}
    end
  end

  @doc """
  The REGISTRATION-time check: scheme, metadata hostnames, and literal-IP
  hosts — deterministic and offline-safe (hostname DNS is the delivery
  runtime's send-time check, per ADR-0005's split).
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
    case resolve(uri, host) do
      {:ok, addresses} -> Enum.all?(addresses, &public_address?/1)
      :error -> false
    end
  end

  # Literal IP hosts skip DNS; hostnames resolve — BOTH families, because
  # ANY answer class can carry the private address that must reject.
  defp resolve(uri, host) do
    bare = host_without_brackets(host)

    case :inet.parse_address(String.to_charlist(bare)) do
      {:ok, address} ->
        {:ok, [address]}

      {:error, _} ->
        case resolved_addresses(uri, String.to_charlist(bare)) do
          [] -> :error
          addresses -> {:ok, addresses}
        end
    end
  end

  # IPv6 literals arrive bracketed in the URL; brackets are not part of
  # the address.
  defp host_without_brackets("[" <> rest), do: String.trim_trailing(rest, "]")
  defp host_without_brackets(host), do: host

  defp resolved_addresses(_uri, charlist) do
    # BOTH families are queried; a family with no answers (or a family
    # resolution error — fail-closed) contributes nothing. What matters is
    # that the UNION is non-empty and every member is public.
    bounded_resolve(charlist, :inet) ++ bounded_resolve(charlist, :inet6)
  end

  # Bounded resolution: a stalled resolver must fail the check, not hang
  # the registration cast (2s wall clock, then fail-closed).
  defp bounded_resolve(charlist, family) do
    task = Task.async(fn -> :inet.gethostbyname(charlist, family) end)

    case Task.yield(task, @resolve_timeout_ms) || Task.shutdown(task, :brutal_kill) do
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
  # documentation ranges (TEST-NET-1/2/3) — reserved, never a real destination
  defp ipv4_public?(192, 0, 2, _), do: false
  defp ipv4_public?(198, 51, 100, _), do: false
  defp ipv4_public?(203, 0, 113, _), do: false
  defp ipv4_public?(a, _, _, _) when a in 224..255, do: false
  defp ipv4_public?(_, _, _, _), do: true

  # Prefix masks per RFC 4291/4193, not single-range checks (cross-vendor
  # finding: fc00::/7 covers fc00–fdff, fe80::/10 covers fe80–febf,
  # ff00::/8 covers ff00–ffff — the old /16 checks let fc00::, fe90:: and
  # ff02:: through).
  defp ipv6_public?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  # ULA fc00::/7
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFE00) == 0xFC00, do: false
  # link-local fe80::/10
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFFC0) == 0xFE80, do: false
  # multicast ff00::/8
  defp ipv6_public?({a, _, _, _, _, _, _, _}) when band(a, 0xFF00) == 0xFF00, do: false
  # transition forms embedding a (possibly private) IPv4 (cross-vendor
  # note): 6to4 2002::/16 and Teredo 2001:0::/32 are refused outright;
  # NAT64 64:ff9b::/96 unwraps its embedded v4
  defp ipv6_public?({0x2002, _, _, _, _, _, _, _}), do: false
  defp ipv6_public?({0x2001, 0, _, _, _, _, _, _}), do: false

  defp ipv6_public?({0x0064, 0xFF9B, _, _, _, _, hi, lo}),
    do:
      ipv4_public?(
        band(hi, 0xFF00) >>> 8,
        band(hi, 0x00FF),
        band(lo, 0xFF00) >>> 8,
        band(lo, 0x00FF)
      )

  defp ipv6_public?(_), do: true
end
