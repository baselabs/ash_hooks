defmodule AshHooks.PrimaryKey do
  @moduledoc """
  Complete, metadata-derived primary-key handling for AshHooks ledgers.

  Ledger ownership always uses every primary-key component declared by the
  consumer resource. A writable attribute named `:id` has no special meaning
  unless it is itself part of that primary key. Encoded keys use the declared
  attribute names as strings for job and audit payloads; decoding accepts only
  that exact known set and casts values through the resource's Ash types
  without creating atoms from input.
  """

  alias Ash.Resource.Info, as: ResourceInfo

  @typedoc "A complete atom-key primary-key map."
  @type key_map :: %{required(atom()) => term()}

  @doc "Returns every declared primary-key component from an Ash record."
  @spec map(struct()) :: key_map()
  def map(%resource{} = record) do
    resource
    |> ResourceInfo.primary_key()
    |> Map.new(fn name -> {name, fetch_complete!(record, name)} end)
  end

  @doc "Returns the complete primary-key filter for an Ash record."
  @spec filter(struct()) :: key_map()
  def filter(record), do: map(record)

  @doc "Returns the sole declared primary-key value from an Ash record."
  @spec scalar!(struct()) :: term()
  def scalar!(%resource{} = record) do
    case ResourceInfo.primary_key(resource) do
      [name] -> fetch_complete!(record, name)
      _ -> raise ArgumentError, "resource must declare exactly one primary-key component"
    end
  end

  @doc "Encodes a record or key map as a JSON-safe string-key map."
  @spec encode(struct() | map()) :: %{required(String.t()) => term()}
  def encode(%_resource{} = record), do: record |> map() |> encode()

  def encode(key) when is_map(key) do
    key
    |> Map.new(fn
      {name, value} when is_atom(name) or is_binary(name) -> {to_string(name), value}
      {_name, _value} -> raise ArgumentError, "primary-key names must be atoms or strings"
    end)
    |> json_safe!()
  end

  @doc """
  Decodes an encoded primary key against the resource's exact key metadata.

  Unknown input names never become atoms. Values are cast and constrained by
  their declared Ash attribute type. Error reasons are fixed atoms so attacker
  input cannot escape through worker or telemetry diagnostics.
  """
  @spec decode(module(), map()) ::
          {:ok, key_map()} | {:error, :primary_key_mismatch | :invalid_primary_key}
  def decode(resource, encoded) when is_atom(resource) and is_map(encoded) do
    attributes = primary_key_attributes(resource)
    expected_names = MapSet.new(attributes, &Atom.to_string(&1.name))

    if MapSet.new(Map.keys(encoded)) == expected_names and
         Enum.all?(Map.keys(encoded), &is_binary/1) do
      decode_values(attributes, encoded)
    else
      {:error, :primary_key_mismatch}
    end
  end

  def decode(_resource, _encoded), do: {:error, :primary_key_mismatch}

  defp primary_key_attributes(resource) do
    resource
    |> ResourceInfo.primary_key()
    |> Enum.map(&ResourceInfo.attribute(resource, &1))
  end

  defp decode_values(attributes, encoded) do
    Enum.reduce_while(attributes, {:ok, %{}}, fn attribute, {:ok, values} ->
      value = Map.fetch!(encoded, Atom.to_string(attribute.name))

      with false <- is_nil(value),
           {:ok, cast} <- Ash.Type.cast_input(attribute.type, value, attribute.constraints),
           {:ok, constrained} <-
             Ash.Type.apply_constraints(attribute.type, cast, attribute.constraints) do
        {:cont, {:ok, Map.put(values, attribute.name, constrained)}}
      else
        _ -> {:halt, {:error, :invalid_primary_key}}
      end
    end)
  end

  defp fetch_complete!(record, name) do
    case Map.fetch(record, name) do
      {:ok, value} when not is_nil(value) -> value
      _ -> raise ArgumentError, "record has an incomplete primary key"
    end
  end

  defp json_safe!(map) do
    map
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _error in [Protocol.UndefinedError, Jason.EncodeError] ->
      reraise ArgumentError,
              [message: "primary key contains a value that is not JSON-safe"],
              __STACKTRACE__
  end
end
