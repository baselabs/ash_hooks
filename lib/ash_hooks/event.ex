defmodule AshHooks.Event do
  @moduledoc """
  An outbound event: its identity, type, exact payload bytes, and optional context.

      {:ok, event} = AshHooks.Event.new(
        id: "msg_order-" <> to_string(order.id),
        type: :order_paid,
        payload: Jason.encode!(%{order_id: order.id})
      )

      AshHooks.dispatch(OrderResource, :order_paid, event)

  Choose a deterministic `id` for each logical event when a producer can run
  again. Reusing that ID lets dispatch recognize an existing delivery and lets
  receivers deduplicate `webhook-id`. A generated ID makes each invocation a
  new event, which can produce a duplicate POST for the same business change.
  If a record can emit several changes, include the change's stable identity
  or revision rather than using the record ID alone.

    * `id` is generated with a `msg_` prefix when omitted or `nil`. Supplied
      IDs do not require that prefix. They must be nonempty UTF-8 binaries,
      at most 255 bytes, without dots, spaces, or control characters. Dots
      delimit the Standard Webhooks signing string. Dispatch also validates
      IDs supplied through direct struct construction before persistence.
    * `type` is an atom or nonempty binary, at most 255 bytes. Construction
      converts atoms to strings, the representation used by subscriptions
      and the delivery ledger.
    * `payload` is a nonempty binary containing the exact bytes to sign and
      send. Serialize once; maps and structs are rejected.
    * `metadata` is a map of unsigned application context, defaulting to `%{}`.
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
  def new(attrs) when is_map(attrs), do: build(Map.to_list(attrs))

  def new(attrs) when is_list(attrs) do
    if Enum.all?(attrs, &match?({_, _}, &1)) do
      build(attrs)
    else
      {:error, "event attributes must be a map or a keyword list"}
    end
  end

  def new(_other), do: {:error, "event attributes must be a map or a keyword list"}

  defp build(attrs) do
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

  # Ids and types are bounded to the ledger's 255-char columns and ids to
  # header-safe characters: the id becomes the `webhook-id` HTTP header at
  # send time, and CR/LF/space in it is a header-injection surface handed
  # to the delivery runtime.
  @doc false
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id), do: is_nil(id_validation_error(id))

  defp validate_id(id) do
    case id_validation_error(id) do
      nil -> {:ok, id}
      reason -> {:error, reason}
    end
  end

  defp id_validation_error(id) when is_binary(id) do
    cond do
      id == "" ->
        "event id must not be empty"

      String.contains?(id, ".") ->
        "event id must not contain a dot (\".\") — it is the canonical-string delimiter"

      byte_size(id) > 255 ->
        "event id must be at most 255 bytes (the ledger column bound)"

      not String.valid?(id) ->
        "event id must be valid UTF-8 (it becomes an HTTP header)"

      contains_control_character?(id) or String.contains?(id, " ") ->
        "event id must not contain whitespace or control characters (it becomes an HTTP header)"

      true ->
        nil
    end
  end

  defp id_validation_error(_other), do: "event id must be a binary"

  defp contains_control_character?(binary) do
    binary
    |> String.to_charlist()
    |> Enum.any?(&(&1 <= 31 or &1 in 127..159))
  end

  defp cast_type(%{type: type}) when is_atom(type) and not is_nil(type),
    do: cast_type(%{type: Atom.to_string(type)})

  # Byte bounds, not String.length (graphemes): the injected event_uuid /
  # event_type attributes carry max_length: 255, which under Ash 3.33's
  # :codepoints mode counts codepoints — a grapheme-counted check here
  # passed values the ledger then rejected (every endpoint's :dispatch
  # create failing on an event the library itself validated). Bytes bound
  # codepoints and graphemes alike, in either counting mode.
  defp cast_type(%{type: type}) when is_binary(type) and type != "" do
    if byte_size(type) <= 255 do
      {:ok, type}
    else
      {:error, "event type must be at most 255 bytes (the ledger column bound)"}
    end
  end

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
