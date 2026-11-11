defmodule AshHooks.Provider.Signature.Key do
  @moduledoc false
  require Record

  Record.defrecordp(
    :certificate,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :tbs_certificate,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :subject_key,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  Record.defrecordp(
    :key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: "public_key/include/OTP-PUB-KEY.hrl")
  )

  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @p384 {1, 3, 132, 0, 34}
  @ed25519 {1, 3, 101, 112}

  def list(keys) do
    keys = keys |> List.wrap() |> Enum.reject(&(&1 == ""))
    if keys == [], do: {:error, :no_webhook_secret}, else: {:ok, keys}
  end

  def decode(key, type) do
    key |> unpack() |> match_type(type)
  catch
    _, _ -> {:error, :invalid_signature}
  end

  defp unpack("-----BEGIN" <> _ = pem) do
    case :public_key.pem_decode(pem) do
      [{:Certificate, der, :not_encrypted}] ->
        cert = :public_key.pkix_decode_cert(der, :otp)
        info = cert |> certificate(:tbsCertificate) |> tbs_certificate(:subjectPublicKeyInfo)
        algorithm = subject_key(info, :algorithm)
        public = subject_key(info, :subjectPublicKey)

        case key_algorithm(algorithm, :algorithm) do
          {1, 2, 840, 113_549, 1, 1, 1} -> public
          @ed25519 -> {public, {:namedCurve, @ed25519}}
          {1, 2, 840, 10_045, 2, 1} -> {public, key_algorithm(algorithm, :parameters)}
          _ -> :invalid
        end

      [{type, _, :not_encrypted} = entry] when type in [:SubjectPublicKeyInfo, :RSAPublicKey] ->
        :public_key.pem_entry_decode(entry)

      _ ->
        :invalid
    end
  end

  defp unpack(key), do: key

  defp match_type({:RSAPublicKey, n, e} = key, :rsa)
       when is_integer(n) and n > 0 and is_integer(e) and e > 0, do: {:ok, key}

  defp match_type({{:ECPoint, point}, {:namedCurve, curve}} = key, :ecdsa)
       when is_binary(point) and curve in [@p256, @p384], do: {:ok, key}

  defp match_type({{:ECPoint, point}, {:namedCurve, curve}} = key, {:ecdsa, curve})
       when is_binary(point) and curve in [@p256, @p384], do: {:ok, key}

  defp match_type({{:ECPoint, point}, {:namedCurve, @ed25519}} = key, :ed25519)
       when is_binary(point) and byte_size(point) == 32, do: {:ok, key}

  defp match_type(key, :ed25519) when is_binary(key) and byte_size(key) == 32,
    do: {:ok, {{:ECPoint, key}, {:namedCurve, @ed25519}}}

  defp match_type(_, _), do: {:error, :invalid_signature}
end
