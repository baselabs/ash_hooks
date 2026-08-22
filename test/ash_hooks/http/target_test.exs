defmodule AshHooks.Http.TargetTest do
  @moduledoc """
  Direct unit coverage for the pinning substrate's pure surface: the
  test-seam resolver (bypass mode), port/host-header derivation, the TLS
  option builder, and IP-literal detection.
  """

  use ExUnit.Case, async: true

  alias AshHooks.Http.Target

  describe "resolve/2 (bypass seam — loopback listeners)" do
    test "an unresolvable hostname is {:error, :unresolved_host}" do
      assert {:error, :unresolved_host} =
               Target.resolve("http://no-such-host.invalid/x", validate_destination: false)
    end

    test "an IPv6 literal resolves to its address (URI strips the brackets)" do
      assert {:ok, %{address: {0, 0, 0, 0, 0, 0, 0, 1}, host: "::1", port: 9}} =
               Target.resolve("http://[::1]:9/x", validate_destination: false)
    end

    test "a non-literal hostname goes through :inet.getaddr" do
      assert {:ok, %{address: {127, 0, 0, 1}}} =
               Target.resolve("http://localhost:9/x", validate_destination: false)
    end
  end

  describe "default_port/1" do
    test "https defaults to 443 and everything else to 80" do
      assert Target.default_port("https") == 443
      assert Target.default_port("http") == 80
      assert Target.default_port("ftp") == 80
    end
  end

  describe "host_header/3" do
    test "the default TLS/HTTP ports elide the port" do
      assert Target.host_header("example.com", 443, "https") == "example.com"
      assert Target.host_header("example.com", 80, "http") == "example.com"
    end

    test "any other port is appended, IPv6 re-bracketed" do
      assert Target.host_header("example.com", 8080, "http") == "example.com:8080"
      assert Target.host_header("::1", 9, "http") == "[::1]:9"
    end
  end

  describe "ssl_options/1" do
    test "a literal-IP destination verifies the chain but disables SNI" do
      opts = Target.ssl_options("127.0.0.1")

      assert Keyword.get(opts, :verify) == :verify_peer
      assert Keyword.get(opts, :depth) == 3
      assert Keyword.get(opts, :server_name_indication) == :disable
      assert match?({:ok, [_ | _]}, {:ok, Keyword.get(opts, :cacerts)})
    end

    test "a named destination carries SNI and the RFC 6125 hostname check" do
      opts = Target.ssl_options("example.com")

      assert Keyword.get(opts, :server_name_indication) == ~c"example.com"
      assert [match_fun: fun] = Keyword.get(opts, :customize_hostname_check)
      assert is_function(fun, 2)
      refute Keyword.has_key?(opts, :cacerts) == false
    end
  end

  describe "ip_literal?/1" do
    test "v4 and v6 literals are literals; hostnames are not" do
      assert Target.ip_literal?("192.0.2.1")
      assert Target.ip_literal?("::1")
      assert Target.ip_literal?("[2001:db8::1]")
      refute Target.ip_literal?("example.com")
    end
  end
end
