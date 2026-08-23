defmodule AshHooks.Http.CertSan do
  @moduledoc """
  iPAddress Subject-Alternative-Name matching for the literal-IP https
  floor (ADR-0009's TLS posture): a destination addressed by IP literal
  has no hostname for RFC 6125 to check, so the peer certificate must
  carry the exact IP in its `iPAddress` SAN — chain validation alone
  would let ANY publicly-trusted cert authenticate the peer.

  Works on the DER bytes `:ssl.peercert/1` returns. Fails CLOSED: a
  malformed certificate, an undecodable SAN extension, or a missing SAN
  never matches.
  """

  @spec ip_san_match?(binary(), :inet.ip_address()) :: boolean()
  def ip_san_match?(der, address) when is_binary(der) do
    cert = :public_key.pkix_decode_cert(der, :plain)
    ip_in_san?(cert, address)
  catch
    # Fail closed on EVERY non-local class: malformed DER RAISES on
    # OTP 27/28, while asn1's der_decode EXITS on invalid tags on OTP 29
    # ({:error, {:asn1, ...}} — probed; a rescue alone cannot catch an
    # exit). The bare catch covers error, exit, and throw alike — a
    # garbage-SAN certificate never crashes the caller (cross-vendor
    # review finding)
    _kind, _reason -> false
  end

  # public_key :plain record shapes (verified against a fixture,
  # 2026-08-22): 'Certificate'{tbsCertificate :: 'TBSCertificate'{...}},
  # with the extensions list at TBSCertificate index 10 (8/9 are the
  # :asn1_NOVALUE uniqueIDs — the pre-extraction code indexed 9 and was
  # dead-on-arrival). The SAN extnID is 2.5.29.17; its extnValue is raw
  # DER re-decoded with the SubjectAltName template, whose general-names
  # carry iPAddress tuples.
  defp ip_in_san?(cert, address) do
    cert
    |> elem(1)
    |> record_field(10)
    |> List.wrap()
    |> Enum.find_value(false, fn ext ->
      with {:Extension, {2, 5, 29, 17}, _crit, san} <- ext,
           {:ok, names} <- decode_san(san),
           ips <- san_ips(names) do
        address in ips
      else
        _ -> false
      end
    end)
  end

  defp record_field(record, index), do: elem(record, index)

  # extnValue arrives as raw DER — re-decode with the SAN template. Malformed
  # SAN bytes EXIT (asn1 invalid-tag) and are caught at ip_san_match?'s
  # catch — failing closed, never crashing the caller.
  defp decode_san(san_der), do: {:ok, :public_key.der_decode(:SubjectAltName, san_der)}

  # der_decode(:SubjectAltName) yields iPAddress as RAW BYTES — a 4-byte
  # binary (IPv4) or 16-byte binary (IPv6). Normalized to the inet tuple
  # forms ({a,b,c,d} / an 8-tuple of 16-bit words) for the match.
  defp san_ips(names) when is_list(names) do
    names
    |> Enum.flat_map(fn
      {:iPAddress, <<a, b, c, d>>} -> [{a, b, c, d}]
      {:iPAddress, ip} when is_binary(ip) and byte_size(ip) == 16 -> [ipv6_tuple(ip)]
      _other -> []
    end)
  end

  defp ipv6_tuple(ip) do
    ip
    |> :binary.bin_to_list()
    |> Enum.chunk_every(2)
    |> Enum.map(fn [hi, lo] -> hi * 256 + lo end)
    |> List.to_tuple()
  end
end
