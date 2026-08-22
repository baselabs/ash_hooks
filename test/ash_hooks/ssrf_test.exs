defmodule AshHooks.SsrfTest do
  @moduledoc """
  The SSRF destination classifier (ADR-0005: enforced at endpoint
  registration AND send time). The guard is a boundary property — every
  case here is the protected mutation (an unsafe destination made to look
  acceptable).
  """

  use ExUnit.Case, async: true

  alias AshHooks.Ssrf

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
  end
end
