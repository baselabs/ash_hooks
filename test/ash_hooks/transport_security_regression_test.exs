defmodule AshHooks.TransportSecurityRegressionTest do
  use ExUnit.Case, async: true

  alias AshHooks.Event
  alias AshHooks.Http.Bounded
  alias AshHooks.Http.Httpc
  alias AshHooks.Http.Target
  alias AshHooks.Ssrf

  @payload ~s({"event":"transport-security"})

  describe "event ids used as HTTP header values" do
    test "reject every ASCII control byte and DEL" do
      for byte <- Enum.to_list(0..31) ++ [127] do
        id = "msg_before" <> <<byte>> <> "after"

        assert {:error, reason} = Event.new(id: id, type: :probe, payload: @payload)
        assert reason =~ "control"
      end

      assert {:error, reason} =
               Event.new(id: "msg_before\u0085after", type: :probe, payload: @payload)

      assert reason =~ "control"
    end

    test "reject invalid UTF-8 without raising" do
      assert {:error, reason} =
               Event.new(id: <<"msg_before", 0xFF, "after">>, type: :probe, payload: @payload)

      assert reason =~ "UTF-8"
    end
  end

  describe "adapter request validation" do
    test "both adapters reject invalid header names before destination resolution" do
      invalid_names = ["", :not_a_binary, <<0xFF>>, "x-ok\r\nx-injected", "x bad", "x:bad"]

      for adapter <- [Bounded, Httpc], name <- invalid_names do
        assert {:error, :invalid_header_name} =
                 adapter.request(:post, "http://127.0.0.1/hook", %{name => "value"}, @payload)
      end

      for adapter <- [Bounded, Httpc] do
        assert {:error, :invalid_header_name} =
                 adapter.request(:post, "http://127.0.0.1/hook", [:malformed], @payload)
      end
    end

    test "both adapters reject every control byte and invalid UTF-8 in header values" do
      invalid_values =
        Enum.map(Enum.to_list(0..31) ++ [127], &("before" <> <<&1>> <> "after")) ++
          ["before\u0085after", <<"before", 0xFF, "after">>, :not_a_binary]

      for adapter <- [Bounded, Httpc], value <- invalid_values do
        assert {:error, :invalid_header_value} =
                 adapter.request(
                   :post,
                   "http://127.0.0.1/hook",
                   %{"x-probe" => value},
                   @payload
                 )
      end
    end

    test "unsupported binary methods never intern caller input" do
      for adapter <- [Bounded, Httpc] do
        method =
          "ash_hooks_unsupported_method_#{inspect(adapter)}_#{System.unique_integer([:positive])}"

        assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(method) end

        assert {:error, :unsupported_method} =
                 adapter.request(method, "http://127.0.0.1/hook", %{}, nil)

        assert_raise ArgumentError, fn -> :erlang.binary_to_existing_atom(method) end
      end
    end

    test "method validation accepts supported binary forms and rejects every other input shape" do
      for adapter <- [Bounded, Httpc] do
        assert {:error, :unsafe_destination} =
                 adapter.request("GET", "http://127.0.0.1/hook", %{}, nil)

        assert {:error, :unsupported_method} =
                 adapter.request(:not_an_http_method, "http://127.0.0.1/hook", %{}, nil)

        assert {:error, :unsupported_method} =
                 adapter.request(123, "http://127.0.0.1/hook", %{}, nil)

        assert {:error, :unsupported_method} =
                 adapter.request(<<0xFF>>, "http://127.0.0.1/hook", %{}, nil)
      end
    end
  end

  describe "special-purpose destination ranges" do
    test "resolve and registration entry points fail closed on invalid and metadata inputs" do
      assert {:error, :unsafe} = Ssrf.resolve_public(:not_a_url)
      assert {:error, :unsafe} = Ssrf.resolve_public("not a url")
      assert {:error, :unsafe} = Ssrf.resolve_public("http://")
      assert {:error, :unsafe} = Ssrf.resolve_public("http://metadata.google.internal/hook")
      refute Ssrf.registration_safe?(:not_a_url)
      assert Ssrf.registration_safe?("https://example.com/hook")
    end

    test "all inspected non-global IPv4 special ranges reject on every literal path" do
      urls = [
        "http://192.0.0.1/hook",
        "http://192.0.0.8/hook",
        "http://192.0.0.170/hook",
        "http://192.0.0.171/hook",
        "http://192.88.99.1/hook",
        "http://198.18.0.1/hook",
        "http://198.19.255.255/hook"
      ]

      for url <- urls do
        refute Ssrf.registration_safe?(url), url
        refute Ssrf.safe_url?(url), url
        assert {:error, :unsafe} = Ssrf.resolve_public(url), url
      end
    end

    test "all inspected non-global IPv6 special ranges reject on every literal path" do
      urls = [
        "http://[::]/hook",
        "http://[64:ff9b:1::1]/hook",
        "http://[100::1]/hook",
        "http://[100:0:0:1::1]/hook",
        "http://[2001::1]/hook",
        "http://[2001:2::1]/hook",
        "http://[2001:db8::1]/hook",
        "http://[3fff::1]/hook",
        "http://[5f00::1]/hook",
        "http://[fec0::1]/hook"
      ]

      for url <- urls do
        refute Ssrf.registration_safe?(url), url
        refute Ssrf.safe_url?(url), url
        assert {:error, :unsafe} = Ssrf.resolve_public(url), url
      end
    end

    test "globally reachable special-purpose exceptions remain accepted" do
      urls = [
        "http://192.0.0.9/hook",
        "http://192.0.0.10/hook",
        "http://[64:ff9b::5db8:d822]/hook",
        "http://[2001:1::1]/hook",
        "http://[2001:1::2]/hook",
        "http://[2001:1::3]/hook",
        "http://[2001:3::1]/hook",
        "http://[2001:4:112::1]/hook",
        "http://[2001:20::1]/hook",
        "http://[2001:30::1]/hook"
      ]

      for url <- urls do
        assert Ssrf.registration_safe?(url), url
        assert Ssrf.safe_url?(url), url
        assert {:ok, %{addresses: [_]}} = Ssrf.resolve_public(url), url
      end
    end
  end

  describe "IPv6 authority serialization" do
    test "brackets IPv6 literals on default and nondefault ports" do
      assert Target.host_header("2606:4700:4700::1111", 80, "http") ==
               "[2606:4700:4700::1111]"

      assert Target.host_header("2606:4700:4700::1111", 443, "https") ==
               "[2606:4700:4700::1111]"

      assert Target.host_header("2606:4700:4700::1111", 8443, "https") ==
               "[2606:4700:4700::1111]:8443"
    end

    test "an expired request deadline refuses even a literal test destination" do
      assert {:error, :timeout} =
               Target.resolve("http://127.0.0.1/hook",
                 validate_destination: false,
                 deadline: System.monotonic_time(:millisecond) - 1
               )
    end
  end
end
