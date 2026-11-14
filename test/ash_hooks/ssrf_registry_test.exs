defmodule AshHooks.SsrfRegistryTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias AshHooks.Ssrf

  # IANA registries retrieved 2026-11-13. These tables preserve every entry,
  # including globally reachable children of non-global parent entries.
  # https://www.iana.org/assignments/iana-ipv4-special-registry/
  # https://www.iana.org/assignments/iana-ipv6-special-registry/
  # https://www.iana.org/assignments/ipv6-unicast-address-assignments/
  # Expected values apply to the first and last address, not the entire prefix.
  # Mapped and NAT64 boundaries embed 0.0.0.0 or 255.255.255.255 and are refused.
  # Teredo and 6to4 stay refused, independent of their allocation status.
  @ipv4 [
    {"0.0.0.0/8", false},
    {"0.0.0.0/32", false},
    {"10.0.0.0/8", false},
    {"100.64.0.0/10", false},
    {"127.0.0.0/8", false},
    {"169.254.0.0/16", false},
    {"172.16.0.0/12", false},
    {"192.0.0.0/24", false},
    {"192.0.0.0/29", false},
    {"192.0.0.8/32", false},
    {"192.0.0.9/32", true},
    {"192.0.0.10/32", true},
    {"192.0.0.170/32", false},
    {"192.0.0.171/32", false},
    {"192.0.2.0/24", false},
    {"192.31.196.0/24", true},
    {"192.52.193.0/24", true},
    {"192.88.99.0/24", false},
    {"192.88.99.2/32", false},
    {"192.168.0.0/16", false},
    {"192.175.48.0/24", true},
    {"198.18.0.0/15", false},
    {"198.51.100.0/24", false},
    {"203.0.113.0/24", false},
    {"240.0.0.0/4", false},
    {"255.255.255.255/32", false}
  ]

  @ipv6 [
    {"::1/128", false},
    {"::/128", false},
    {"::ffff:0:0/96", false},
    {"64:ff9b::/96", false},
    {"64:ff9b:1::/48", false},
    {"100::/64", false},
    {"100:0:0:1::/64", false},
    {"2001::/23", false},
    {"2001::/32", false},
    {"2001:1::1/128", true},
    {"2001:1::2/128", true},
    {"2001:1::3/128", true},
    {"2001:2::/48", false},
    {"2001:3::/32", true},
    {"2001:4:112::/48", true},
    {"2001:10::/28", false},
    {"2001:20::/28", true},
    {"2001:30::/28", true},
    {"2001:db8::/32", false},
    {"2002::/16", false},
    {"2620:4f:8000::/48", true},
    {"3fff::/20", false},
    {"5f00::/16", false},
    {"fc00::/7", false},
    {"fe80::/10", false}
  ]

  @allocated_prefixes ~w(
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

  @allocations [
    {"2001::/23", false},
    {"2001:200::/23", true},
    {"2001:400::/23", true},
    {"2001:600::/23", true},
    {"2001:800::/22", true},
    {"2001:c00::/23", true},
    {"2001:e00::/23", true},
    {"2001:1200::/23", true},
    {"2001:1400::/22", true},
    {"2001:1800::/23", true},
    {"2001:1a00::/23", true},
    {"2001:1c00::/22", true},
    {"2001:2000::/19", true},
    {"2001:4000::/23", true},
    {"2001:4200::/23", true},
    {"2001:4400::/23", true},
    {"2001:4600::/23", true},
    {"2001:4800::/23", true},
    {"2001:4a00::/23", true},
    {"2001:4c00::/23", true},
    {"2001:5000::/20", true},
    {"2001:8000::/19", true},
    {"2001:a000::/20", true},
    {"2001:b000::/20", true},
    {"2002::/16", false},
    {"2003::/18", true},
    {"2400::/12", true},
    {"2410::/12", true},
    {"2600::/12", true},
    {"2610::/23", true},
    {"2620::/23", true},
    {"2630::/12", true},
    {"2800::/12", true},
    {"2a00::/12", true},
    {"2a10::/12", true},
    {"2c00::/12", true},
    {"2d00::/8", false},
    {"2e00::/7", false},
    {"3000::/5", false},
    {"3800::/6", false},
    {"3c00::/7", false},
    {"3e00::/8", false},
    {"3f00::/9", false},
    {"3f80::/10", false},
    {"3fc0::/11", false},
    {"3fe0::/12", false},
    {"3ff0::/13", false},
    {"3ff8::/14", false},
    {"3ffc::/15", false},
    {"3ffe::/16", false},
    {"3fff::/20", false}
  ]

  for {registry, entries} <- [ipv4: @ipv4, ipv6: @ipv6, allocations: @allocations],
      {prefix, public?} <- entries do
    test "IANA 2026-11-13 #{registry} #{prefix}: first and last address" do
      {first, last, bits} = prefix_range(unquote(prefix))

      for number <- Enum.uniq([first, last]) do
        assert_classification(address(number, bits), unquote(public?))
      end
    end
  end

  test "IANA 2026-11-13 every unallocated gap inside 2000::/3 is refused" do
    {first, last, 128} = prefix_range("2000::/3")

    # Include all allocations, even those (IETF and 6to4) refused by policy.
    allocated =
      @allocated_prefixes
      |> Enum.map(&prefix_range/1)
      |> Enum.sort()

    next =
      Enum.reduce(allocated, first, fn {start, finish, 128}, next ->
        if next < start, do: assert_classification(address(next, 128), false)
        max(next, finish + 1)
      end)

    if next <= last, do: assert_classification(address(next, 128), false)
  end

  test "IANA 2026-11-13 every unassigned /3 outside 2000::/3 is refused" do
    for first <- [0, 0x4000, 0x6000, 0x8000, 0xA000, 0xC000, 0xE000] do
      assert_classification({first, 0, 0, 0, 0, 0, 0, 1}, false)
    end
  end

  test "IPv4 multicast boundaries are refused" do
    assert_classification({224, 0, 0, 0}, false)
    assert_classification({239, 255, 255, 255}, false)
  end

  defp prefix_range(prefix) do
    [host, length] = String.split(prefix, "/")
    {:ok, ip} = :inet.parse_address(String.to_charlist(host))
    bits = if tuple_size(ip) == 4, do: 32, else: 128
    width = div(bits, tuple_size(ip))
    first = Enum.reduce(Tuple.to_list(ip), 0, fn part, acc -> (acc <<< width) + part end)
    {first, first + (1 <<< (bits - String.to_integer(length))) - 1, bits}
  end

  defp address(number, bits) do
    width = if bits == 32, do: 8, else: 16

    for shift <- (div(bits, width) - 1)..0//-1,
        do: band(number >>> (shift * width), (1 <<< width) - 1)
  end

  defp assert_classification(parts, public?) when is_list(parts),
    do: assert_classification(List.to_tuple(parts), public?)

  defp assert_classification(ip, public?) do
    host = ip |> :inet.ntoa() |> List.to_string()
    authority = if tuple_size(ip) == 8, do: "[#{host}]", else: host
    url = "https://#{authority}/hook"
    assert Ssrf.registration_safe?(url) == public?, "registration: #{host}"
    assert Ssrf.safe_url?(url) == public?, "URL check: #{host}"

    if public? do
      assert {:ok, %{addresses: [^ip]}} = Ssrf.resolve_public(url)
      assert {:ok, [^ip]} = Ssrf.resolve_host_public(host)
    else
      assert {:error, :unsafe} = Ssrf.resolve_public(url)
      assert {:error, :unsafe} = Ssrf.resolve_host_public(host)
    end
  end
end
