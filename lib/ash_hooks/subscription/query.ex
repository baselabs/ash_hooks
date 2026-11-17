defmodule AshHooks.Subscription.Query do
  @moduledoc false
  import Ash.Expr
  require Ash.Query

  alias Ash.Resource.Info
  alias Spark.Dsl.Extension

  def select(resource, event) do
    layer = Ash.DataLayer.data_layer(resource)
    types = types(resource, event.type, layer)
    pause = pause(resource, layer)
    filters = filters(resource, event.metadata, layer)
    Ash.Query.filter(resource, ^types and ^pause and ^filters)
  end

  defp types(resource, name, layer) do
    attribute = Info.attribute(resource, :event_types)

    values = attribute |> allowed_types(name) |> valid_type_names(layer)

    cond do
      values == :unknown or not array_storage?(resource, attribute, layer) ->
        true

      values == [] ->
        false

      layer == AshPostgres.DataLayer ->
        names = Enum.map(values, &to_string/1)
        expr(fragment("?::text[] && ?::text[]", event_types, ^names))

      layer in [AshSqlite.DataLayer, Ash.DataLayer.Ets, Ash.DataLayer.Simple] ->
        Enum.reduce(values, false, fn value, acc -> expr(^acc or ^value in event_types) end)

      true ->
        true
    end
  end

  defp allowed_types(%{type: {:array, Ash.Type.String}}, name), do: Enum.uniq([name, "*"])

  defp allowed_types(%{type: {:array, Ash.Type.Atom}, constraints: constraints}, name) do
    case constraints |> Keyword.get(:items, []) |> Keyword.get(:one_of) do
      nil -> :unknown
      atoms -> Enum.filter(atoms, &(Atom.to_string(&1) in [name, "*"]))
    end
  end

  defp allowed_types(_attribute, _name), do: :unknown

  defp valid_type_names(:unknown, _layer), do: :unknown

  defp valid_type_names(values, layer) do
    Enum.filter(values, fn value ->
      text = to_string(value)

      String.valid?(text) and
        (layer != AshPostgres.DataLayer or not String.contains?(text, <<0>>))
    end)
  end

  defp pause(resource, layer) do
    attribute = Info.attribute(resource, :paused)

    if Extension.get_opt(resource, [:subscription], :pausable, :off) == :on and
         match?(%{type: Ash.Type.Boolean}, attribute) and
         storage(resource, attribute, layer) in [:boolean, :bool, :integer] do
      expr(not paused)
    else
      true
    end
  end

  defp filters(resource, metadata, layer) do
    attribute = Info.attribute(resource, :event_filters)

    cond do
      not match?(%{type: Ash.Type.Map}, attribute) ->
        true

      layer in [Ash.DataLayer.Ets, Ash.DataLayer.Simple] ->
        matcher = fn filters ->
          AshHooks.Subscription.matches_filters?(
            struct(resource, event_filters: filters),
            metadata
          )
        end

        fragment = %Ash.Query.Call{name: :fragment, args: [matcher, expr(event_filters)]}
        expr(is_nil(event_filters) or ^fragment)

      layer == AshPostgres.DataLayer and storage(resource, attribute, layer) in [:map, :jsonb] ->
        sql_filters(resource, metadata, :postgres)

      layer == AshSqlite.DataLayer and
          storage(resource, attribute, layer) in [:map, :text, :string] ->
        sql_filters(resource, metadata, :sqlite)

      true ->
        true
    end
  end

  defp sql_filters(resource, metadata, layer) do
    keys =
      for key <- Extension.get_opt(resource, [:subscription], :filter_attributes, []),
          key = to_string(key),
          Map.has_key?(metadata, key),
          do: key

    if Enum.all?(keys, &json_text?(&1, layer)) do
      {sql, args} = object_subset(keys, layer)

      {sql, args} =
        Enum.reduce(keys, {sql, args}, &scalar_filter(&1, metadata, layer, &2))

      {sql, args} = container(sql, args, layer)
      %Ash.Query.Call{name: :fragment, args: [sql | args]}
    else
      true
    end
  end

  defp scalar_filter(key, metadata, layer, {sql, args}) do
    value = Map.fetch!(metadata, key)

    if is_nil(value) or is_boolean(value) or (is_binary(value) and json_text?(value, layer)) do
      {predicate, parameters} = scalar(key, value, layer)
      {sql <> " AND " <> predicate, args ++ parameters}
    else
      {sql, args}
    end
  end

  defp object_subset(keys, :postgres),
    do: {"(? - ?::text[]) = '{}'::jsonb", [expr(event_filters), keys]}

  defp object_subset(keys, :sqlite),
    do:
      {"NOT EXISTS (SELECT 1 FROM json_each(?) AS hooks_key WHERE hooks_key.key NOT IN (SELECT value FROM json_each(?)))",
       [expr(event_filters), Jason.encode!(keys)]}

  defp scalar(key, value, :postgres) do
    {"(NOT jsonb_exists(?, ?::text) OR jsonb_typeof(? -> ?::text) IN ('array','number','object') OR (? -> ?::text) = ?::text::jsonb)",
     [
       expr(event_filters),
       key,
       expr(event_filters),
       key,
       expr(event_filters),
       key,
       Jason.encode!(value)
     ]}
  end

  defp scalar(key, value, :sqlite) do
    {kind, native} =
      case value do
        nil -> {"null", nil}
        true -> {"true", 1}
        false -> {"false", 0}
        text -> {"text", text}
      end

    # Duplicate object keys are outside the map encoding contract. Widen that
    # key because JSON decoders can choose a different occurrence than SQLite.
    {"((SELECT count(*) FROM json_each(?) AS hooks_duplicate WHERE hooks_duplicate.key = ?) > 1 OR NOT EXISTS (SELECT 1 FROM json_each(?) AS hooks_value WHERE hooks_value.key = ? AND hooks_value.type IN ('text','true','false','null') AND NOT (hooks_value.type = ? AND hooks_value.value IS ?)))",
     [expr(event_filters), key, expr(event_filters), key, kind, native]}
  end

  defp container(sql, args, :postgres),
    do:
      {"CASE WHEN ? IS NULL OR jsonb_typeof(?) = 'null' THEN true WHEN jsonb_typeof(?) = 'object' THEN (" <>
         sql <> ") ELSE false END",
       [expr(event_filters), expr(event_filters), expr(event_filters) | args]}

  defp container(sql, args, :sqlite),
    do:
      {"CASE WHEN ? IS NULL THEN 1 WHEN NOT json_valid(?) THEN 0 WHEN json_type(?) = 'null' THEN 1 WHEN json_type(?) = 'object' THEN (" <>
         sql <> ") ELSE 0 END",
       [expr(event_filters), expr(event_filters), expr(event_filters), expr(event_filters) | args]}

  defp json_text?(text, layer),
    do: String.valid?(text) and (layer != :postgres or not String.contains?(text, <<0>>))

  defp array_storage?(resource, attribute, AshPostgres.DataLayer = layer),
    do:
      storage(resource, attribute, layer) in [
        {:array, :string},
        {:array, :text},
        {:array, :atom},
        {:array, Ash.Type.String},
        {:array, Ash.Type.Atom}
      ]

  defp array_storage?(resource, attribute, AshSqlite.DataLayer = layer),
    do:
      storage(resource, attribute, layer) in [
        {:array, :string},
        {:array, :text},
        {:array, :atom},
        :text,
        :string
      ]

  defp array_storage?(_resource, _attribute, _layer), do: true

  defp storage(_resource, nil, _layer), do: nil

  defp storage(resource, attribute, layer) do
    path =
      case layer do
        AshPostgres.DataLayer -> [:postgres]
        AshSqlite.DataLayer -> [:sqlite]
        _memory -> []
      end

    default = Ash.Type.storage_type(attribute.type, attribute.constraints)

    if path == [],
      do: default,
      else:
        Keyword.get(
          Extension.get_opt(resource, path, :storage_types, []),
          attribute.name,
          default
        )
  end
end
