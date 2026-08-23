defmodule AshHooks.CertSanTest do
  @moduledoc """
  iPAddress-SAN matching against committed certificate fixtures — the
  logic the literal-IP https floor rests on. Found broken by dialyzer on
  2026-08-22: `:public_key.pkix_decode_cert/2` returns the cert record
  DIRECTLY (never an `{:ok, cert}` tuple), so the original `with` chain
  never reached the matcher and EVERY literal-IP https endpoint was
  rejected with `:cert_ip_mismatch` (fail-closed, but broken). Fixtures
  are self-signed — appropriate here: this tests OUR decode/extract/match
  pipeline, not a provider's signature contract.

  The `verify_ip_san` orchestration around it (peercert + wiring) is three
  lines directly readable in `AshHooks.Http.Bounded`; driving it live would
  need a TLS listener with a chain-trusted cert, which a unit fixture
  cannot honestly provide.
  """

  use ExUnit.Case, async: true

  alias AshHooks.Http.CertSan

  defp cert_der(fixture) do
    [entry] = :public_key.pem_decode(File.read!("test/fixtures/#{fixture}"))
    {:Certificate, der, :not_encrypted} = entry
    der
  end

  describe "ip_san_match?/2" do
    test "matches the IPv4 SAN the cert carries" do
      assert CertSan.ip_san_match?(cert_der("ip-san-cert.pem"), {127, 0, 0, 1})
    end

    test "rejects an address the cert does not carry" do
      refute CertSan.ip_san_match?(cert_der("ip-san-cert.pem"), {127, 0, 0, 2})
    end

    test "a cert with no iPAddress SAN never matches" do
      refute CertSan.ip_san_match?(cert_der("no-ip-san-cert.pem"), {127, 0, 0, 1})
    end

    test "garbage-SAN extnValue EXITS at asn1 and is caught — fails closed, never crashes" do
      # a well-formed chain whose SAN extension carries non-DER bytes:
      # der_decode EXITS ({:error, {:asn1, ...}}) — uncatchable by rescue,
      # the failure class the cross-vendor review found
      [{:Certificate, der, _}] =
        :public_key.pem_decode(File.read!("test/fixtures/bad-san-cert.pem"))

      assert AshHooks.Http.CertSan.ip_san_match?(der, {127, 0, 0, 1}) == false
    end

    test "garbage DER fails closed (no raise, no match)" do
      refute CertSan.ip_san_match?("not a certificate", {127, 0, 0, 1})
    end

    test "matches the IPv6 SAN the cert carries (inet 8-tuple of 16-bit words)" do
      # 2001:db8::1 — the inet form is {0x2001, 0x0db8, 0, 0, 0, 0, 0, 1}
      assert CertSan.ip_san_match?(
               cert_der("ipv6-san-cert.pem"),
               {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 1}
             )
    end

    test "an IPv6 address the cert does not carry never matches" do
      refute CertSan.ip_san_match?(
               cert_der("ipv6-san-cert.pem"),
               {0x2001, 0x0DB8, 0, 0, 0, 0, 0, 2}
             )

      refute CertSan.ip_san_match?(cert_der("ipv6-san-cert.pem"), {0, 0, 0, 0, 0, 0, 0, 1})
    end
  end
end
