defmodule AshHooks.SsrfTest do
  @moduledoc """
  The SSRF destination classifier (ADR-0005: enforced at endpoint
  registration AND send time). The guard is a boundary property — every
  case here is the protected mutation (an unsafe destination made to look
  acceptable).
  """

  use ExUnit.Case, async: true

  alias AshHooks.Ssrf

  describe "allocated IPv6 destinations" do
    for host <- ["4000::1", "3000::1"] do
      test "refuses unallocated #{host} at registration and resolution" do
        url = "https://[#{unquote(host)}]/hook"
        refute Ssrf.registration_safe?(url)
        refute Ssrf.safe_url?(url)
        assert {:error, :unsafe} = Ssrf.resolve_public(url)
      end
    end

    test "an allocated public address and the existing global exceptions stay admitted" do
      for host <- [
            "2606:4700:4700::1111",
            "2001:1::1",
            "2001:1::2",
            "2001:1::3",
            "2001:3::1",
            "2001:4:112::1",
            "2001:20::1",
            "2001:30::1"
          ] do
        assert Ssrf.safe_url?("https://[#{host}]/hook"), host
      end
    end
  end

  describe "resolve_host_public/2" do
    for {class, hosts} <- [
          malformed_brackets: [
            "[",
            "]",
            "[]",
            "[::1",
            "::1]",
            "[[::1]]",
            "[example.com]",
            "[8.8.8.8]"
          ],
          zone_identifiers: ["fe80::1%eth0", "[fe80::1%eth0]", "[fe80::1%25eth0]"],
          ports: ["example.com:443", "8.8.8.8:443", "[2606:4700:4700::1111]:443"],
          schemes: ["https://example.com", "http:example.com", "//example.com"],
          paths: [
            "example.com/hook",
            "example.com\\hook",
            "example.com?x=1",
            "example.com#fragment"
          ],
          credentials: ["user@example.com", "user:password@example.com"],
          whitespace: [" example.com", "example.com ", "exam ple.com", "example.com\u00A0"],
          empty_labels: ["", ".", "..", ".example.com", "example..com", "example.com.."],
          invalid_labels: [
            "-example.com",
            "example-.com",
            "éxample.com",
            String.duplicate("x", 64) <> ".com",
            Enum.join(List.duplicate(String.duplicate("x", 63), 4), ".")
          ],
          non_hosts: [nil, 42, :example, ~c"example.com", %{}, <<0xFF>>]
        ] do
      test "#{class} return invalid_host without raising" do
        for host <- unquote(Macro.escape(hosts)) do
          assert {:error, :invalid_host} = Ssrf.resolve_host_public(host), inspect(host)
        end
      end
    end

    test "control characters return invalid_host without raising" do
      for byte <- Enum.to_list(0..31) ++ Enum.to_list(127..159) do
        host = "exam" <> <<byte::utf8>> <> "ple.com"
        assert {:error, :invalid_host} = Ssrf.resolve_host_public(host), inspect(host)
      end
    end

    test "bare IPv4, bare IPv6 and bracketed IPv6 literals skip DNS" do
      assert {:ok, [{8, 8, 8, 8}]} = Ssrf.resolve_host_public("8.8.8.8")
      ip = {0x2606, 0x4700, 0x4700, 0, 0, 0, 0, 0x1111}
      assert {:ok, [^ip]} = Ssrf.resolve_host_public("2606:4700:4700::1111")
      assert {:ok, [^ip]} = Ssrf.resolve_host_public("[2606:4700:4700::1111]")
    end

    test "mapped, compatible and NAT64 forms use the embedded IPv4 classifier" do
      for prefix <- ["::ffff:", "::", "64:ff9b::"] do
        assert {:error, :unsafe} = Ssrf.resolve_host_public(prefix <> "10.0.0.1")
        assert {:ok, [_]} = Ssrf.resolve_host_public(prefix <> "8.8.8.8")
      end
    end

    test "metadata names are refused case insensitively with or without a trailing dot" do
      for host <- ["metadata.google.internal", "metadata.goog"],
          name <- [host, host <> ".", String.upcase(host), String.upcase(host) <> "."] do
        assert {:error, :unsafe} = Ssrf.resolve_host_public(name)
        assert {:error, :unsafe} = Ssrf.resolve_public("https://#{name}/hook")
      end
    end

    test "options cannot bypass destination checks" do
      assert {:error, :unsafe} =
               Ssrf.resolve_host_public("127.0.0.1",
                 validate_destination: false,
                 destination_policy: fn _, _ -> :allow end
               )
    end

    @tag :ssrf_dns
    test "a public DNS name accepts a trailing dot and returns every system resolver address" do
      for host <- ["example.com", "EXAMPLE.COM."] do
        expected =
          for family <- [:inet, :inet6],
              {:ok, {:hostent, _, _, _, _, addresses}} <- [
                :inet.gethostbyname(String.to_charlist(host), family)
              ],
              ip <- addresses,
              do: ip

        assert expected != []
        assert {:ok, addresses} = Ssrf.resolve_host_public(host)
        assert Enum.sort(addresses) == Enum.sort(expected)
      end
    end

    @tag :ssrf_dns
    test "a name resolving to loopback is unsafe" do
      assert {:error, :unsafe} = Ssrf.resolve_host_public("localhost")
    end

    @tag :ssrf_dns
    test "underscore labels resolve instead of being refused as malformed" do
      for host <- ["_service.no-such-host-ash-hooks-test.invalid", "no_such_host.invalid"] do
        assert {:error, reason} = Ssrf.resolve_host_public(host), host
        assert reason in [:nxdomain, :resolve_timeout], host
        assert {:error, url_reason} = Ssrf.resolve_public("https://#{host}/hook")
        assert url_reason in [:nxdomain, :resolve_timeout], host
      end
    end

    @tag :ssrf_dns
    test "an unresolved name keeps the existing failure vocabulary" do
      assert {:error, reason} = Ssrf.resolve_host_public("no-such-host-ash-hooks-test.invalid")
      assert reason in [:nxdomain, :resolve_timeout]
    end

    test "an expired deadline is honored before querying a real DNS name" do
      started = System.monotonic_time(:millisecond)

      assert {:error, :resolve_timeout} =
               Ssrf.resolve_host_public("example.com", deadline: started - 1)

      assert System.monotonic_time(:millisecond) - started < 250
    end
  end

  describe "scheme" do
    test "accepts http and https" do
      assert Ssrf.safe_url?("http://example.com/hook")
      assert Ssrf.safe_url?("https://example.com/hook")
    end

    test "rejects every other scheme" do
      for url <- [
            "ftp://example.com/f",
            "file:///etc/passwd",
            "gopher://example.com/x",
            "javascript:alert(1)",
            "data:text/plain,hi",
            "unix:///var/run/sock"
          ] do
        refute Ssrf.safe_url?(url), "#{url} must be refused"
      end
    end

    test "rejects garbage" do
      refute Ssrf.safe_url?("")
      refute Ssrf.safe_url?("not a url")
      refute Ssrf.safe_url?(nil)
      refute Ssrf.safe_url?("http://")
    end
  end

  describe "host literal addresses (no DNS — deterministic)" do
    test "rejects loopback in v4 and v6" do
      refute Ssrf.safe_url?("http://127.0.0.1/x")
      refute Ssrf.safe_url?("http://127.1.2.3/x")
      refute Ssrf.safe_url?("http://[::1]/x")
      refute Ssrf.safe_url?("http://localhost/x")
    end

    test "rejects RFC1918 private ranges" do
      refute Ssrf.safe_url?("http://10.0.0.1/x")
      refute Ssrf.safe_url?("http://10.255.255.255/x")
      refute Ssrf.safe_url?("http://172.16.0.1/x")
      refute Ssrf.safe_url?("http://172.31.255.255/x")
      refute Ssrf.safe_url?("http://192.168.1.1/x")
    end

    test "rejects link-local, metadata, CGNAT, and unspecified/reserved" do
      refute Ssrf.safe_url?("http://169.254.169.254/latest/meta-data/")
      refute Ssrf.safe_url?("http://169.254.0.1/x")
      refute Ssrf.safe_url?("http://100.64.0.1/x")
      refute Ssrf.safe_url?("http://0.0.0.0/x")
      refute Ssrf.safe_url?("http://192.0.2.1/x")
      refute Ssrf.safe_url?("http://198.51.100.1/x")
      refute Ssrf.safe_url?("http://203.0.113.1/x")
      refute Ssrf.safe_url?("http://240.0.0.1/x")
    end

    test "rejects IPv6 ULA and link-local, including IPv4-mapped private" do
      refute Ssrf.safe_url?("http://[fd00::1]/x")
      refute Ssrf.safe_url?("http://[fe80::1]/x")
      # ::ffff:127.0.0.1 is the loopback in disguise
      refute Ssrf.safe_url?("http://[::ffff:127.0.0.1]/x")
      refute Ssrf.safe_url?("http://[::ffff:10.0.0.1]/x")
    end

    test "rejects the FULL ULA/link-local/multicast prefix blocks (review regressions)" do
      # fc00::/7 covers fc00–fdff; fe80::/10 covers fe80–febf; ff00::/8
      # covers ff00–ffff — single-range checks let these through (the
      # reviewers' live probes)
      refute Ssrf.safe_url?("http://[fc00::1]/x")
      refute Ssrf.safe_url?("http://[fe90::1]/x")
      refute Ssrf.safe_url?("http://[ff02::1]/x")
    end

    test "rejects IPv4-embedding transition forms (6to4, Teredo, NAT64-private)" do
      # 2002:0a00:0001:: is 6to4 wrapping 10.0.0.1
      refute Ssrf.safe_url?("http://[2002:0a00:1::]/x")
      # 64:ff9b::a00:1 is NAT64 wrapping 10.0.0.1
      refute Ssrf.safe_url?("http://[64:ff9b::a00:1]/x")
    end

    test "accepts public literals (incl. IPv4-mapped public)" do
      assert Ssrf.safe_url?("http://93.184.216.34/x")
      assert Ssrf.safe_url?("http://[2606:2800:220:1:248:1893:25c8:1946]/x")
      assert Ssrf.safe_url?("http://[::ffff:93.184.216.34]/x")
    end
  end

  describe "known metadata hostnames (list-based — resolution-independent)" do
    test "rejects cloud metadata endpoints" do
      refute Ssrf.safe_url?("http://metadata.google.internal/computeMetadata/")
      refute Ssrf.safe_url?("http://metadata.goog/x")
    end
  end

  describe "DNS resolution (every answer must be public)" do
    @tag :ssrf_dns
    test "a public hostname resolves and is accepted" do
      assert Ssrf.safe_url?("https://example.com/hook")
    end

    @tag :ssrf_dns
    test "a hostname with NO resolution is rejected (fail-closed)" do
      refute Ssrf.safe_url?("https://no-such-host-ash-hooks-test.invalid/x")
    end

    @tag :ssrf_dns
    test "a hostname with NO resolution carries the failure vocabulary" do
      # the live resolver's answer is environment-dependent (authoritative
      # negative vs blocked/slow resolver) — the deterministic branches are
      # pinned below through the pure combiner
      assert {:error, reason} =
               Ssrf.resolve_public("https://no-such-host-ash-hooks-test.invalid/x")

      assert reason in [:nxdomain, :resolve_timeout]
    end

    test "combine_family_results: any address wins over every failure" do
      assert {:ok, [{1, 2, 3, 4}]} =
               Ssrf.combine_family_results([{:ok, [{1, 2, 3, 4}]}, {:error, :nxdomain}])
    end

    test "combine_family_results: nxdomain requires EVERY family negative" do
      assert {:error, :nxdomain} =
               Ssrf.combine_family_results([{:error, :nxdomain}, {:error, :nxdomain}])
    end

    test "combine_family_results: timeout, temporary failure, or mixed evidence is the retryable label" do
      assert {:error, :resolve_timeout} =
               Ssrf.combine_family_results([
                 {:error, :resolve_timeout},
                 {:error, :resolve_timeout}
               ])

      # one authoritative negative + one unanswered question: not a verdict
      assert {:error, :resolve_timeout} =
               Ssrf.combine_family_results([{:error, :nxdomain}, {:error, :resolve_timeout}])
    end

    test "an expired deadline classifies as resolve_timeout, never nxdomain" do
      # both family queries are killed at the shared deadline before any
      # answer exists — the deterministic form of an outage
      assert {:error, :resolve_timeout} =
               Ssrf.resolve_public("https://example.com/hook",
                 deadline: System.monotonic_time(:millisecond) - 1
               )
    end
  end
end
