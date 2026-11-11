defmodule AshHooks.TestBatchProvider do
  @moduledoc false
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-batch-signature"},
      encoding: :base64,
      timestamp: {:header, "x-batch-timestamp"},
      timestamp_unit: :milliseconds,
      signed_input: [:method, :url, :body, :timestamp]
    ]

  @identity_namespace "test:batch:"
  @impl true
  def event_identity(events) when is_list(events) and events != [] do
    if Enum.all?(events, &identity_event?/1) do
      canonical_events =
        events
        |> Enum.map(fn event ->
          event
          |> Map.delete("attemptNumber")
          |> canonical_value()
          |> Jason.encode!()
        end)
        |> Enum.sort()

      identity =
        :crypto.hash(:sha256, @identity_namespace <> Jason.encode!(canonical_events))
        |> Base.encode16(case: :lower)

      {:ok, identity}
    else
      {:error, :malformed_payload}
    end
  end

  def event_identity(_payload), do: {:error, :malformed_payload}

  defp canonical_value(value) when is_map(value) do
    value
    |> Enum.map(fn {key, nested} -> {key, canonical_value(nested)} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Jason.OrderedObject.new()
  end

  defp canonical_value(value) when is_list(value), do: Enum.map(value, &canonical_value/1)
  defp canonical_value(value), do: value

  defp identity_event?(%{"subscriptionType" => type}) when is_binary(type), do: true
  defp identity_event?(_event), do: false
end
