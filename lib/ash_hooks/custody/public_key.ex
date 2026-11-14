defmodule AshHooks.Custody.PublicKey do
  @moduledoc """
  A pinned sender public key with its host-selected asymmetric algorithm.

  Unlike `AshHooks.Custody.Key`, this value contains public verification
  material and never calls a custodian. Providers receive this struct rather
  than untyped bytes. HMAC verifiers refuse it with `KeyKindMismatch`.

  `new/2` validates the key before a source is created or updated. Kinds are
  `{:standard_webhooks, :v1a}` for a `whpk_` Ed25519 key, `:ed25519`,
  `:rsa_pkcs1_sha256`, `:rsa_pkcs1_sha384`, `:rsa_pkcs1_sha512`,
  `:rsa_pss_sha256`, `:rsa_pss_sha384`, `:rsa_pss_sha512`,
  `:ecdsa_p256_sha256`, and `:ecdsa_p384_sha384`. The kind pins the digest,
  RSA padding, and ECDSA curve as well as the key family.
  """

  alias AshHooks.Provider.Signature.Key

  @enforce_keys [:kind, :key]
  defstruct [:kind, :key]

  @type kind ::
          {:standard_webhooks, :v1a}
          | :ed25519
          | :rsa_pkcs1_sha256
          | :rsa_pkcs1_sha384
          | :rsa_pkcs1_sha512
          | :rsa_pss_sha256
          | :rsa_pss_sha384
          | :rsa_pss_sha512
          | :ecdsa_p256_sha256
          | :ecdsa_p384_sha384
  @type t :: %__MODULE__{kind: kind(), key: term()}

  @p256 {1, 2, 840, 10_045, 3, 1, 7}
  @p384 {1, 3, 132, 0, 34}
  @algorithms %{
    rsa_pkcs1_sha256: {:rsa, :sha256, :pkcs1_v1_5},
    rsa_pkcs1_sha384: {:rsa, :sha384, :pkcs1_v1_5},
    rsa_pkcs1_sha512: {:rsa, :sha512, :pkcs1_v1_5},
    rsa_pss_sha256: {:rsa, :sha256, :pss},
    rsa_pss_sha384: {:rsa, :sha384, :pss},
    rsa_pss_sha512: {:rsa, :sha512, :pss},
    ecdsa_p256_sha256: {{:ecdsa, @p256}, :sha256, nil},
    ecdsa_p384_sha384: {{:ecdsa, @p384}, :sha384, nil},
    ed25519: {:ed25519, :none, nil}
  }

  @doc "Validates public verification material under a closed asymmetric kind."
  @spec new(term(), term()) :: {:ok, t()} | {:error, struct()}
  def new(key, kind) do
    pin = %__MODULE__{kind: kind, key: key}
    with {:ok, _} <- decode(pin, algorithm(kind)), do: {:ok, pin}
  end

  @doc false
  def decode(%__MODULE__{} = pin, {type, _, _} = algorithm) do
    with true <- algorithm(pin.kind) == algorithm,
         {:ok, key} <- material(pin),
         {:ok, decoded} <- Key.decode(key, type) do
      {:ok, decoded}
    else
      _ -> mismatch()
    end
  end

  def decode(%__MODULE__{}, _), do: mismatch()

  defp algorithm({:standard_webhooks, :v1a}), do: {:ed25519, :none, nil}
  defp algorithm(kind), do: Map.get(@algorithms, kind)

  defp material(%{kind: {:standard_webhooks, :v1a}, key: "whpk_" <> encoded}) do
    case Base.decode64(encoded) do
      {:ok, key} when byte_size(key) == 32 -> {:ok, key}
      _ -> :error
    end
  end

  defp material(%{kind: {:standard_webhooks, :v1a}}), do: :error
  defp material(%{key: key}), do: {:ok, key}
  defp mismatch, do: AshHooks.Errors.from_custody_result({:error, :kind_mismatch})
end
