defmodule AshHooks.Http.CertificatePin do
  @moduledoc false

  require Record

  Record.defrecordp(
    :certificate,
    :Certificate,
    Record.extract(:Certificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs,
    :TBSCertificate,
    Record.extract(:TBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  def validate(nil, _scheme), do: :ok

  def validate(pin, scheme) do
    cond do
      not valid?(pin) -> {:error, :invalid_certificate_pin}
      scheme != "https" -> {:error, :certificate_pin_requires_https}
      true -> :ok
    end
  end

  defp valid?({:certificate, der}), do: is_binary(der) and byte_size(der) > 0

  defp valid?({kind, digest}) when kind in [:sha256, :spki_sha256],
    do: is_binary(digest) and byte_size(digest) == 32

  defp valid?(_pin), do: false

  @spec verify(:ssl.sslsocket(), term()) :: :ok | {:error, :certificate_pin_mismatch}
  def verify(_socket, nil), do: :ok

  def verify(socket, pin) do
    with {:ok, der} <- :ssl.peercert(socket),
         {expected, actual} <- digests(der, pin),
         true <- :crypto.hash_equals(expected, actual) do
      :ok
    else
      _ -> {:error, :certificate_pin_mismatch}
    end
  end

  defp digests(der, {:certificate, pinned}),
    do: {:crypto.hash(:sha256, pinned), :crypto.hash(:sha256, der)}

  defp digests(der, {:sha256, hash}), do: {hash, :crypto.hash(:sha256, der)}

  defp digests(der, {:spki_sha256, hash}) do
    cert = :public_key.pkix_decode_cert(der, :plain)
    spki = cert |> certificate(:tbsCertificate) |> tbs(:subjectPublicKeyInfo)
    {hash, :crypto.hash(:sha256, :public_key.der_encode(:SubjectPublicKeyInfo, spki))}
  end
end
