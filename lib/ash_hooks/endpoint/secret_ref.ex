defmodule AshHooks.Endpoint.SecretRef do
  @moduledoc """
  A reference to a consumer-held secret — never the secret itself.

  The cast rejects any value carrying a live secret's shape (`whsec_` /
  `whsk_` / `whpk_` prefix, the Standard Webhooks secret encodings): a
  literal pasted into an endpoint row is the exact leak ADR-0005's
  callback-only rule exists to prevent, and because the rejection lives in
  the TYPE it holds on every write path — the package's actions, and any
  consumer-defined create/update that accepts the attribute.
  """

  use Ash.Type

  @secret_prefixes ~w(whsec_ whsk_ whpk_)

  @impl true
  def storage_type(_), do: :text

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) when is_binary(value) do
    cond do
      # allow_nil? blocks only nil — the empty string must be refused by the
      # type itself or a required endpoint persists an unusable reference
      # (cross-vendor finding).
      value == "" ->
        {:error,
         "must be a non-empty secret REFERENCE — an empty reference cannot resolve a secret"}

      Enum.any?(@secret_prefixes, &String.starts_with?(value, &1)) ->
        {:error,
         "must be a secret REFERENCE, not secret material — store the consumer-side key that resolves the secret, never the secret itself (ADR-0005)"}

      true ->
        {:ok, value}
    end
  end

  def cast_input(_value, _constraints),
    do: {:error, "must be a non-empty binary secret reference"}

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(value, _constraints) when is_binary(value), do: {:ok, value}
  def cast_stored(_value, _constraints), do: {:error, "invalid stored secret reference"}

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(value, _constraints) when is_binary(value), do: {:ok, value}
  def dump_to_native(_value, _constraints), do: {:error, "invalid secret reference"}
end
