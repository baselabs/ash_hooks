defmodule AshHooks.Http.CertificatePinTest do
  use ExUnit.Case, async: false
  alias AshHooks.Http.Bounded
  alias AshHooks.Test.HttpReceiver
  @dir "test/fixtures/tls/"

  setup do
    {server, port} =
      HttpReceiver.start(
        socket_type:
          {:ssl,
           [
             certfile: String.to_charlist(@dir <> "server-both-san.pem"),
             keyfile: String.to_charlist(@dir <> "server.key")
           ]}
      )

    on_exit(fn -> :inets.stop(:httpd, server) end)
    [{:Certificate, ca, _}] = :public_key.pem_decode(File.read!(@dir <> "local-ca.pem"))

    [{:Certificate, certificate, _}] =
      :public_key.pem_decode(File.read!(@dir <> "server-both-san.pem"))

    %{
      url: "https://127.0.0.1:#{port}/status/200",
      opts: [validate_destination: false, cacerts: [ca]],
      certificate: certificate
    }
  end

  test "the default-off and matching certificate pins send; mismatch sends no request", ctx do
    for pin <- [
          nil,
          {:certificate, ctx.certificate},
          {:sha256, :crypto.hash(:sha256, ctx.certificate)}
        ] do
      assert {:ok, %{status: 200}} =
               Bounded.request(
                 :post,
                 ctx.url,
                 %{},
                 "exact body",
                 Keyword.put(ctx.opts, :certificate_pin, pin)
               )

      assert_receive {:http_received, %{body: "exact body"}}
    end

    assert {:error, :certificate_pin_mismatch} =
             Bounded.request(
               :post,
               ctx.url,
               %{},
               "must not send",
               Keyword.put(ctx.opts, :certificate_pin, {:sha256, :binary.copy(<<0>>, 32)})
             )

    refute_receive {:http_received, _}, 50
  end

  test "SPKI pin hashes the DER SubjectPublicKeyInfo, not the certificate or RSA modulus", ctx do
    # Independent OpenSSL output for the fixture certificate, not the code's hash helper.
    {encoded, 0} =
      System.cmd("sh", [
        "-c",
        "openssl x509 -in test/fixtures/tls/server-both-san.pem -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -binary | openssl base64 -A"
      ])

    pin = {:spki_sha256, Base.decode64!(encoded)}

    assert {:ok, %{status: 200}} =
             Bounded.request(
               :post,
               ctx.url,
               %{},
               "public key pin",
               Keyword.put(ctx.opts, :certificate_pin, pin)
             )

    assert_receive {:http_received, %{body: "public key pin"}}

    assert {:error, :certificate_pin_mismatch} =
             Bounded.request(
               :post,
               ctx.url,
               %{},
               "must not send",
               Keyword.put(
                 ctx.opts,
                 :certificate_pin,
                 {:spki_sha256, :crypto.hash(:sha256, ctx.certificate)}
               )
             )

    refute_receive {:http_received, _}, 50
  end

  test "invalid pins and plaintext destinations fail closed before a request", ctx do
    for pin <- [{:sha256, "short"}, {:spki_sha256, nil}, {:unknown, "anything"}, false] do
      assert {:error, :invalid_certificate_pin} =
               Bounded.request(
                 :post,
                 ctx.url,
                 %{},
                 "must not send",
                 Keyword.put(ctx.opts, :certificate_pin, pin)
               )
    end

    assert {:error, :certificate_pin_requires_https} =
             Bounded.request(
               :post,
               String.replace_prefix(ctx.url, "https:", "http:"),
               %{},
               "must not send",
               Keyword.put(ctx.opts, :certificate_pin, {:certificate, ctx.certificate})
             )

    refute_received {:http_received, _}
  end

  test "a matching pin never bypasses CA verification", ctx do
    assert {:error, :certificate_pin_mismatch} =
             Bounded.request(
               :get,
               ctx.url,
               %{},
               nil,
               Keyword.put(ctx.opts, :certificate_pin, {:certificate, "wrong certificate"})
             )

    assert {:error, _} =
             Bounded.request(:get, ctx.url, %{}, nil,
               validate_destination: false,
               certificate_pin: {:certificate, ctx.certificate}
             )

    refute_received {:http_received, _}
  end
end
