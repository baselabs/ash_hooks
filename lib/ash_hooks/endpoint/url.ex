defmodule AshHooks.Endpoint.Url do
  @moduledoc """
  An outbound webhook destination URL with registration-time validation.

  Input casting requires an HTTP or HTTPS scheme and a host, rejects known
  metadata hostnames, and rejects non-global literal IPv4 and IPv6 addresses,
  including mapped and compatible IPv6 forms. Consumer actions using this type
  apply the same validation as the package's endpoint actions.

  Hostname registration does not resolve DNS. The delivery runtime resolves
  and validates the destination at send time, so casting remains independent
  of network availability.
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
