defmodule AshHooks.Endpoint.Url do
  @moduledoc """
  An outbound webhook destination URL, validated at EVERY write path by
  living in the type: http(s) scheme, host not a known metadata name, and
  a literal-IP host (v4, v6, mapped/compatible v6) never in a
  private/loopback/link-local/reserved range (ADR-0005's registration-time
  floor — deterministic and offline-safe).

  DNS resolution of HOSTNAME urls is deliberately NOT done here: the
  ADR assigns send-time DNS re-resolution to the delivery runtime, and
  cast-time resolution would make every changeset network-dependent.
  """
  use Ash.Type

  @impl true
  def storage_type(_), do: :text

  @impl true
  def cast_input(nil, _constraints), do: {:ok, nil}

  def cast_input(value, _constraints) when is_binary(value) do
    if AshHooks.Ssrf.registration_safe?(value) do
      {:ok, value}
    else
      {:error,
       "must be an http(s) webhook URL whose literal host is not a private/loopback/link-local/metadata address — not a safe webhook destination (ADR-0005)"}
    end
  end

  def cast_input(_value, _constraints), do: {:error, "must be a URL string"}

  @impl true
  def cast_stored(nil, _constraints), do: {:ok, nil}

  def cast_stored(value, _constraints) when is_binary(value), do: {:ok, value}
  def cast_stored(_value, _constraints), do: {:error, "invalid stored url"}

  @impl true
  def dump_to_native(nil, _constraints), do: {:ok, nil}

  def dump_to_native(value, _constraints) when is_binary(value), do: {:ok, value}
  def dump_to_native(_value, _constraints), do: {:error, "invalid url"}
end
