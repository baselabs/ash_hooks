defmodule AshHooks.CountingProvider do
  @moduledoc false
  # Test provider: HMAC-SHA256 over the raw body (default implementation),
  # event type from `payload["type"]` via String.to_existing_atom, and a
  # handler that reports every invocation to a registered sink process and
  # returns a configurable outcome.
  #
  # Sink/outcome are passed via :persistent_term under {__MODULE__, key} —
  # tests register in setup and MUST delete the keys on teardown (config
  # restore rule: delete when unset).

  @behaviour AshHooks.Provider
  alias AshHooks.Provider

  def put_sink(pid), do: :persistent_term.put({__MODULE__, :sink}, pid)

  def put_outcome(outcome), do: :persistent_term.put({__MODULE__, :outcome}, outcome)

  def cleanup do
    :persistent_term.erase({__MODULE__, :sink})
    :persistent_term.erase({__MODULE__, :outcome})
  end

  @impl Provider
  def verify_signature(raw_body, ctx, secret) do
    Provider.default_verify_signature(raw_body, ctx.signature, secret, :hmac_sha256)
  end

  @impl Provider
  def parse_event_type(%{"type" => type}) when is_binary(type) do
    case String.to_existing_atom(type) do
      scalar when scalar in [nil, true, false] -> {:error, :malformed_payload}
      type_atom -> {:ok, type_atom}
    end
  rescue
    ArgumentError -> {:error, :unknown_event_type}
  end

  def parse_event_type(%{"type" => type})
      when is_atom(type) and type not in [nil, true, false],
      do: {:ok, type}

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  @impl Provider
  def handle_event(event_type, payload) do
    if pid = :persistent_term.get({__MODULE__, :sink}, nil) do
      send(pid, {:handled, event_type, payload})
    end

    case :persistent_term.get({__MODULE__, :outcome}, :ok) do
      :ok -> {:ok, %{type: event_type, payload: payload}}
      {:error, kind, term} when kind in [:retry, :permanent] -> {:error, kind, term}
    end
  end
end
