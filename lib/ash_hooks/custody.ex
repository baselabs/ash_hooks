defmodule AshHooks.Custody do
  @moduledoc """
  Custody of opaque webhook keys. Secret bytes never return to ash_hooks
  after `c:store/4`.

  ## Material and kinds

  `material` is decoded cryptographic material only: raw HMAC key bytes or
  an Ed25519 seed. The caller decodes `whsec_`, `whsk_`, base64, hex, and
  provider encodings. Custody never parses wire prefixes or encodings.

    * `{:standard_webhooks, :v1}`: HMAC-SHA256, 24 to 64 bytes, sign and verify.
    * `{:standard_webhooks, :v1a}`: Ed25519, exactly a 32-byte seed, sign
      and verify; its public half may be disclosed.
    * `{:sender_hmac, digest}`: `:sha1`, `:sha256`, `:sha384`, or `:sha512`,
      1 to 16,384 decoded bytes as issued, verify only. Signing returns
      `{:error, :not_signable}`.
    * `{:legacy_hmac, :sha256}`: at least one byte as issued, with no ceiling,
      sign and verify. Even prefix-shaped material is stored byte for byte.

  Import bounds are not generation policy. Package-generated spec and legacy
  keys use 32 cryptographically random bytes; sender keys are never generated
  or admitted to an endpoint slot.

  The kind is fixed at store. Every `expected_kind` is an assertion and must
  be checked before computing. A mismatch returns `{:error, :kind_mismatch}`.
  Verification compares the full decoded MAC in constant time and refuses
  truncated MACs with `{:error, :invalid_signature}`.

  `:unavailable` means custody could not answer and is retryable. Every other
  error is final for that attempt. ash_hooks classifies backend errors without
  exposing their terms.

  ## References, tenant binding, and destruction

  ash_hooks chooses `"ahk_" <> UUIDv7` references, one per slot occupancy;
  references are never shared. Store is idempotent for the exact reference,
  material, kind, and tenant. Other reuse of a live reference returns the
  `:ref_exists` error.

  A reference is bound globally and atomically to the canonical tenant of
  its first store or destroy. Reference uniqueness is global, never per tenant.
  For another tenant, sign, verify, public-key disclosure, and fingerprint
  return `{:error, :unknown_ref}` without computing or revealing existence.
  Store returns `:ref_exists` for a live reference and `:ref_destroyed` for a
  tombstoned reference. Destroy returns `{:error, :tenant_mismatch}` and
  changes nothing, leaving the original tenant's key working.

  Destroy is idempotent under the bound tenant, succeeds for a never-stored
  reference, and leaves a permanent tombstone for the life of the custody
  store. Every later store returns `{:error, :ref_destroyed}`. Store and
  destroy of a reference must be linearizable: the second operation sees
  the first, including a delayed store arriving after destruction. A destroy
  under A then store under B, or destroy under B of an absent reference then
  store under A, both refuse store with `:ref_destroyed`. Store under A then
  destroy under B refuses destroy with `:tenant_mismatch`.

  Canonical tenants come from `canonical_tenant/3`, using the owner resource's
  create-path conversion. Non-multitenant owners use `nil`. Attribute tenancy
  supports UUID, UUIDv7, integer, string, and case-insensitive string. For any
  other type the host supplies `custody_tenant_key: {module, function, args}`.
  It receives the cast value followed by `args` and must return the same
  UTF-8 binary for values the database treats as equal. This equality
  contract belongs to the host. `tenant_type_supported?/2` lets resource
  verifiers check coverage at compile time. Context tenancy is unsupported.

  ## Fingerprints

  For v1 and v1a, `c:fingerprint/3` returns the first 16 bytes of
  `SHA-256("ash_hooks key fingerprint v1\\0" <> kind_label <> "\\0" <> key_bytes)`.
  The labels are `standard_webhooks.v1` and `standard_webhooks.v1a`.
  `key_bytes` is the exact stored HMAC material for v1, and the Ed25519
  public key derived from the seed for v1a. Custody returns the digest only;
  ash_hooks formats `"SHA256:" <> unpadded_base64url(digest)`.

  Sender and legacy kinds return `{:error, :no_fingerprint}`. An unkeyed
  fingerprint of an as-issued secret could enable offline guessing.
  Display fingerprints are safe to show for securely generated keys; this
  truncated, domain-separated hash does not protect weak or predictable
  secrets from offline guessing. It is distinct from the correlation-only
  `AshHooks.Telemetry.fingerprint/1`.

  Custodians can run `AshHooks.Custody.Conformance` in their test suite against
  a fresh real store to exercise these contracts.
  """

  alias Ash.Resource.Info
  alias AshHooks.Custody.{Fingerprint, Key}
  alias AshHooks.Errors

  @type tenant :: String.t() | nil
  @type ref :: String.t()
  @type kind ::
          {:standard_webhooks, :v1}
          | {:standard_webhooks, :v1a}
          | {:sender_hmac, :sha1 | :sha256 | :sha384 | :sha512}
          | {:legacy_hmac, :sha256}

  @callback store(ref(), material :: binary(), tenant(), kind()) ::
              :ok
              | {:error, :ref_exists | :ref_destroyed | :invalid_material | :unavailable | term()}
  @callback sign(ref(), tenant(), expected_kind :: kind(), input :: binary()) ::
              {:ok, binary()}
              | {:error, :kind_mismatch | :not_signable | :unknown_ref | :unavailable | term()}
  @callback verify(ref(), tenant(), expected_kind :: kind(), input :: binary(), mac :: binary()) ::
              :ok
              | {:error,
                 :invalid_signature | :kind_mismatch | :unknown_ref | :unavailable | term()}
  @callback public_key(ref(), tenant(), expected_kind :: kind()) ::
              {:ok, binary()}
              | {:error, :kind_mismatch | :no_public_half | :unknown_ref | :unavailable | term()}
  @callback fingerprint(ref(), tenant(), expected_kind :: kind()) ::
              {:ok, <<_::128>>}
              | {:error, :kind_mismatch | :no_fingerprint | :unknown_ref | :unavailable | term()}
  @callback destroy(ref(), tenant()) ::
              :ok | {:error, :tenant_mismatch | :unavailable | term()}

  @doc """
  Derives canonical custody text from a tenant and its owner resource.

  Applies `Ash.ToTenant.to_tenant/2`, the multitenancy `parse_attribute`, and
  `Ash.Type.cast_input/3` with the tenant attribute's constraints, in that
  order. UUIDs are lowercase hyphenated text, integers are decimal, strings
  are exact valid UTF-8, and ci_strings are downcased. Other types require
  the `:custody_tenant_key` MFA option described in the module contract.

  Returns `{:error, :invalid_tenant}` for invalid inputs and hook results,
  or `{:error, :unsupported_tenant_type}` for uncovered tenant types or
  unsupported tenancy declarations. Non-multitenant resources return
  `{:ok, nil}` without interpreting the supplied tenant.
  """
  @spec canonical_tenant(term(), module(), keyword()) ::
          {:ok, tenant()} | {:error, :invalid_tenant | :unsupported_tenant_type}
  def canonical_tenant(tenant, owner_resource, opts \\ []) do
    case Info.multitenancy_strategy(owner_resource) do
      nil -> {:ok, nil}
      :attribute -> canonical_attribute_tenant(tenant, owner_resource, opts)
      _ -> {:error, :unsupported_tenant_type}
    end
  end

  @doc """
  Whether an owner's tenant type has a canonical custody representation.

  Accepts a resource module or the DSL state available to a compile-time
  verifier. No tenant value or custody call is needed. Other types are
  covered only with a `:custody_tenant_key` MFA option. This function checks
  coverage; it does not install a verifier on a resource.
  """
  @spec tenant_type_supported?(module() | map(), keyword()) :: boolean()
  def tenant_type_supported?(owner_resource, opts \\ []) do
    case Info.multitenancy_strategy(owner_resource) do
      nil ->
        true

      :attribute ->
        attribute = Info.attribute(owner_resource, Info.multitenancy_attribute(owner_resource))

        not is_nil(attribute) and
          (builtin_type?(attribute.type) or valid_hook?(opts[:custody_tenant_key]))

      _ ->
        false
    end
  end

  @doc """
  Displays a custody key's fingerprint as `SHA256:` plus unpadded base64url.

  v1 and v1a ask the custodian for the 16-byte digest defined in the module
  contract. Sender and legacy kinds return `{:error, :no_fingerprint}`
  without calling custody. Custody errors become classified package errors,
  including `AshHooks.Errors.Invalid.KeyKindMismatch` for a kind mismatch.

  Safe to show for securely generated keys. This hash does not protect a
  weak or predictable secret against offline guessing.
  """
  @spec display_fingerprint(Key.t()) :: {:ok, String.t()} | {:error, struct() | :no_fingerprint}
  def display_fingerprint(%Key{kind: {family, _}}) when family in [:sender_hmac, :legacy_hmac],
    do: {:error, :no_fingerprint}

  def display_fingerprint(%Key{custodian: custodian, ref: ref, tenant: tenant, kind: kind}) do
    case custodian.fingerprint(ref, tenant, kind) do
      {:ok, <<_::128>> = digest} -> {:ok, Fingerprint.display(digest)}
      {:error, _} = error -> Errors.from_custody_result(error)
      _ -> Errors.from_custody_result(:invalid_fingerprint_result)
    end
  end

  defp canonical_attribute_tenant(tenant, resource, opts) do
    if tenant_type_supported?(resource, opts) do
      attribute = Info.attribute(resource, Info.multitenancy_attribute(resource))
      {module, function, args} = Info.multitenancy_parse_attribute(resource)

      with parsed <- apply(module, function, [Ash.ToTenant.to_tenant(tenant, resource) | args]),
           {:ok, value} when not is_nil(value) <-
             Ash.Type.cast_input(attribute.type, parsed, attribute.constraints) do
        canonical_text(value, attribute.type, opts[:custody_tenant_key])
      else
        _ -> {:error, :invalid_tenant}
      end
    else
      {:error, :unsupported_tenant_type}
    end
  end

  defp builtin_type?(type),
    do:
      type in [
        Ash.Type.UUID,
        Ash.Type.UUIDv7,
        Ash.Type.Integer,
        Ash.Type.String,
        Ash.Type.CiString
      ]

  defp valid_hook?({module, function, args}),
    do: is_atom(module) and is_atom(function) and is_list(args)

  defp valid_hook?(_), do: false

  defp canonical_text(value, type, _hook) when type in [Ash.Type.UUID, Ash.Type.UUIDv7],
    do: {:ok, String.downcase(value)}

  defp canonical_text(value, Ash.Type.Integer, _hook), do: {:ok, Integer.to_string(value)}
  defp canonical_text(value, Ash.Type.String, _hook), do: valid_text(value)

  defp canonical_text(value, Ash.Type.CiString, _hook) do
    with {:ok, text} <- valid_text(Ash.CiString.value(value)), do: {:ok, String.downcase(text)}
  end

  defp canonical_text(value, _type, {module, function, args}),
    do: valid_text(apply(module, function, [value | args]))

  defp valid_text(value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: {:error, :invalid_tenant}
  end

  defp valid_text(_), do: {:error, :invalid_tenant}
end
