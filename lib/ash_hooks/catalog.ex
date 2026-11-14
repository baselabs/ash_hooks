defmodule AshHooks.Catalog do
  @moduledoc """
  The event catalog read surface: the `outbound` DSL's declared metadata
  (each event type's description, payload schema, and version), read back
  for event pickers, doc generation, and payload-version negotiation.

      webhooks do
        outbound :order_paid do
          description "An order reached the paid state."
          payload_schema MyApp.Schemas.OrderPaid
          version 2
          # endpoints pinning 1 receive this builder's bytes instead:
          payload_versions %{1 => {MyApp.Payloads, :order_paid_v1}}
        end
      end

  `entries/1` lists a resource's declared catalog; `entry/2` reads one.
  `payload/3` resolves the bytes a dispatch sends to one endpoint: its
  pinned variant when it pinned a declared version, the dispatch payload
  otherwise.

  A pin on a version the declaration does not carry fails that endpoint
  closed (`{:error, :unknown_pinned_version}`) BEFORE any delivery row is
  written, as does a variant builder that fails or returns a non-binary
  (`{:error, :variant_failed}`; a crash is contained the same way).
  """

  alias AshHooks.{Event, Info}

  @typedoc "One catalog entry: the declared metadata for an outbound event type."
  @type entry :: %{
          name: atom(),
          description: String.t() | nil,
          payload_schema: term() | nil,
          example: String.t() | nil,
          version: pos_integer(),
          payload_versions: %{optional(pos_integer()) => {module(), atom()}} | nil
        }

  @doc """
  The resource's declared outbound catalog, in declaration order: the
  event picker's source. Compose across your emitting resources yourself;
  each entry carries everything a doc generator needs.
  """
  @spec entries(module()) :: {:ok, [entry()]}
  def entries(resource) do
    catalog =
      resource
      |> Info.webhooks()
      |> Enum.filter(&is_struct(&1, AshHooks.Outbound))
      |> Enum.map(fn outbound ->
        %{
          name: outbound.name,
          description: outbound.description,
          payload_schema: outbound.payload_schema,
          example: outbound.example,
          version: outbound.version || 1,
          payload_versions: outbound.payload_versions
        }
      end)

    {:ok, catalog}
  end

  @doc """
  One declared outbound entry, or `:error` when the resource declares no
  such event type.
  """
  @spec entry(module(), atom()) :: {:ok, entry()} | :error
  def entry(resource, name) do
    case entries(resource) do
      {:ok, catalog} ->
        case Enum.find(catalog, &(&1.name == name)) do
          nil -> :error
          found -> {:ok, found}
        end
    end
  end

  @doc """
  Resolves the payload bytes a dispatch delivers to one endpoint: the
  pinned variant's when the endpoint pinned a DECLARED version, the
  event's own bytes otherwise. The dispatch payload is returned verbatim
  for endpoints that never pinned, pinned the current version, or whose
  resource carries no pinning column at all.
  """
  @spec payload(Event.t(), AshHooks.Outbound.t(), struct()) ::
          {:ok, binary()} | {:error, :unknown_pinned_version | :variant_failed}
  def payload(%Event{} = event, outbound, endpoint) do
    pinned = Map.get(endpoint, :pinned_payload_version)
    versions = outbound.payload_versions || %{}
    current = outbound.version || 1

    cond do
      is_nil(pinned) or pinned == current ->
        {:ok, event.payload}

      Map.has_key?(versions, pinned) ->
        apply_variant(Map.fetch!(versions, pinned), event)

      true ->
        {:error, :unknown_pinned_version}
    end
  end

  # a variant builder that fails, returns junk, or crashes fails that
  # endpoint closed — never the whole fanout, never a row with wrong bytes
  defp apply_variant({module, function}, event)
       when is_atom(module) and is_atom(function) do
    case apply(module, function, [event]) do
      {:ok, payload} when is_binary(payload) and payload != "" ->
        {:ok, payload}

      {:ok, _not_bytes} ->
        {:error, :variant_failed}

      {:error, _reason} ->
        {:error, :variant_failed}
    end
  rescue
    _reason -> {:error, :variant_failed}
  catch
    :exit, _reason -> {:error, :variant_failed}
    :throw, _value -> {:error, :variant_failed}
  end
end
