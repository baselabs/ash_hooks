defmodule AshHooks.Event do
  @moduledoc """
  The outbound pipeline's unit of work — what a consumer emits and the
  fanout dispatcher delivers.

      {:ok, event} = AshHooks.Event.new(type: :order_paid, payload: Jason.encode!(order))

      AshHooks.dispatch(OrderResource, :order_paid, event)

  Contract:

    * `id` — the webhook id (`msg_`-prefixed, URL-safe, NEVER
      `.`-carrying: `.` is the canonical-string delimiter of the Standard
      Webhooks signature, `msg_id.timestamp.payload`). Generated when
      absent; a caller-supplied id that is non-binary, empty, or carries a
      `.` is rejected (the signing path enforces the same constraint —
      this keeps the rejection at the boundary, before anything persists).
    * `type` — atom or binary, canonicalized to a STRING at construction:
      strings are the single representation the subscription filter, the
      delivery ledger, and the outbound DSL name compare on.
    * `payload` — the exact BINARY bytes to sign and send. Structs and
      maps are rejected: signing re-encoded maps is the interoperability
      failure that kept the official Elixir reference library unusable.
    * `metadata` — a map of non-signed context (default `%{}`).
  """

  defstruct [:id, :type, :payload, metadata: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          type: String.t(),
          payload: binary(),
          metadata: map()
        }

  @doc """
  Builds a validated event. Returns `{:ok, %AshHooks.Event{}}` or
  `{:error, reason}` — never raises on caller input.
  """
  @spec new(keyword() | map()) :: {:ok, t()} | {:error, String.t()}
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    attrs = Map.new(attrs)

    with {:ok, id} <- cast_id(attrs),
         {:ok, type} <- cast_type(attrs),
         {:ok, payload} <- cast_payload(attrs),
         {:ok, metadata} <- cast_metadata(attrs) do
      {:ok, %__MODULE__{id: id, type: type, payload: payload, metadata: metadata}}
    end
  end

  defp cast_id(%{id: nil}), do: {:ok, AshHooks.Signing.generate_msg_id()}
  defp cast_id(attrs) when is_map_key(attrs, :id), do: validate_id(attrs.id)
  defp cast_id(_attrs), do: {:ok, AshHooks.Signing.generate_msg_id()}

  defp validate_id(id) when is_binary(id) do
    cond do
      id == "" ->
        {:error, "event id must not be empty"}

      String.contains?(id, ".") ->
        {:error, "event id must not contain a dot (\".\") — it is the canonical-string delimiter"}

      true ->
        {:ok, id}
    end
  end

  defp validate_id(_other), do: {:error, "event id must be a binary"}

  defp cast_type(%{type: type}) when is_atom(type) and not is_nil(type),
    do: {:ok, Atom.to_string(type)}

  defp cast_type(%{type: type}) when is_binary(type) and type != "", do: {:ok, type}
  defp cast_type(_other), do: {:error, "event type is required (atom or non-empty binary)"}

  defp cast_payload(%{payload: payload}) when is_binary(payload) and payload != "",
    do: {:ok, payload}

  defp cast_payload(%{payload: _other}),
    do: {:error, "event payload must be a non-empty binary — the exact bytes to sign"}

  defp cast_payload(_attrs),
    do: {:error, "event payload must be a non-empty binary — the exact bytes to sign"}

  defp cast_metadata(%{metadata: metadata}) when is_map(metadata), do: {:ok, metadata}
  defp cast_metadata(%{metadata: _other}), do: {:error, "event metadata must be a map"}
  defp cast_metadata(_attrs), do: {:ok, %{}}
end
