defmodule AshHooks.Keyset do
  @moduledoc """
  Shared keyset pagination over a stable `(time, id)` ordering: newest
  first, opaque cursors, and `{:ok, %{records:, next_cursor:}}` pages.

  The cursor is the last row's `{time, id}` pair as base64url-encoded JSON.
  It is stable across engines because the page query filters by tuple order
  (`time < cursor.time OR (time == cursor.time AND id < cursor.id)` under
  the matching `DESC, DESC` sort), never by offset. `id` is the tiebreak
  for rows sharing one timestamp.
  """

  alias Ash.Resource.Info

  @default_limit 50
  @max_limit 500

  @typedoc "A page result: the records and the cursor for the next page (nil on a shorter page; a full page carries a cursor even if it is the final nonempty page)."
  @type page(records) :: {:ok, %{records: records, next_cursor: binary() | nil}}

  @doc "The page size in force: the default when unset, a validation error outside 1..500."
  @spec fetch_limit(keyword()) :: {:ok, pos_integer()} | {:error, :invalid_limit}
  def fetch_limit(opts) do
    case opts[:limit] do
      nil -> {:ok, @default_limit}
      n when is_integer(n) and n in 1..@max_limit -> {:ok, n}
      _invalid -> {:error, :invalid_limit}
    end
  end

  @doc """
  Decodes a page cursor into `%{time: DateTime.t(), id: term()}`. `nil`
  (the first page) decodes to `{:ok, nil}`; anything malformed is the
  named `{:error, :invalid_cursor}`; attacker-shaped cursors never raise.
  """
  @spec decode_cursor(binary() | nil) ::
          {:ok, nil | %{time: DateTime.t(), id: term()}} | {:error, :invalid_cursor}
  def decode_cursor(nil), do: {:ok, nil}

  def decode_cursor(encoded) when is_binary(encoded) do
    with {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, %{"time" => time, "id" => id}} when is_binary(time) <- Jason.decode(json),
         {:ok, time, _offset} <- DateTime.from_iso8601(time) do
      {:ok, %{time: DateTime.truncate(time, :microsecond), id: id}}
    else
      _malformed -> {:error, :invalid_cursor}
    end
  end

  def decode_cursor(_other), do: {:error, :invalid_cursor}

  @doc """
  The page query's cursor predicate: everything strictly older than the
  cursor under the `(time DESC, id DESC)` ordering. `read_page/5` skips
  this for the first page (no cursor).
  """
  @spec cursor_filter(%{time: DateTime.t(), id: term()}, atom()) :: Ash.Expr.t()
  def cursor_filter(cursor, time_field) do
    require Ash.Expr

    time = Ash.Expr.ref(time_field)

    # sort is (time DESC, id DESC): older rows are strictly smaller in the
    # tuple order: a lexicographic less-than on (time, id)
    Ash.Expr.expr(
      ^time < ^cursor.time or (^time == ^cursor.time and ^Ash.Expr.ref(:id) < ^cursor.id)
    )
  end

  @doc """
  Reads one page: sorts newest-first, applies the limit, and returns the
  `t:page/1` result shape. `time_field` must exist on the resource (the caller's
  pre-flight checks it; `:inserted_at` on consumer ledgers is optional).
  """
  @spec read_page(module(), keyword(), atom(), (Ash.Query.t() -> Ash.Query.t()), term()) ::
          page([struct()]) | {:error, term()}
  def read_page(resource, opts, time_field, filter_fun, tenant) do
    with {:ok, limit} <- fetch_limit(opts),
         {:ok, cursor} <- decode_cursor(opts[:after]),
         {:ok, cursor} <- cast_cursor_id(resource, cursor) do
      query =
        resource
        |> Ash.Query.new()
        |> filter_fun.()
        |> apply_cursor(cursor, time_field)
        |> Ash.Query.sort([{time_field, :desc}, {:id, :desc}])
        |> Ash.Query.limit(limit)

      case Ash.read(query, authorize?: false, tenant: tenant) do
        {:ok, records} -> {:ok, page_result(records, limit, time_field)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # a decoded cursor's id must cast to the resource's own id type, or a
  # tampered id would surface as a query error instead of the named one
  defp cast_cursor_id(_resource, nil), do: {:ok, nil}

  defp cast_cursor_id(_resource, %{id: nil}), do: {:error, :invalid_cursor}

  # the cast runs on attacker-shaped input, and some types' casts raise on
  # values they cannot represent (a float id given an integer too large for
  # a float), so the cast is contained
  defp cast_cursor_id(resource, %{id: id} = cursor) do
    with %{type: type, constraints: constraints} <- Info.attribute(resource, :id),
         {:ok, cast} when not is_nil(cast) <- Ash.Type.cast_input(type, id, constraints) do
      {:ok, %{cursor | id: cast}}
    else
      _invalid -> {:error, :invalid_cursor}
    end
  rescue
    _raised -> {:error, :invalid_cursor}
  end

  defp apply_cursor(query, nil, _time_field), do: query

  defp apply_cursor(query, cursor, time_field),
    do: Ash.Query.do_filter(query, cursor_filter(cursor, time_field))

  defp page_result(records, limit, time_field) when length(records) == limit,
    do: %{records: records, next_cursor: encode_cursor(List.last(records), time_field)}

  defp page_result(records, _limit, _time_field), do: %{records: records, next_cursor: nil}

  @doc """
  Encodes a row's `(time_field, id)` pair as the opaque page cursor.
  """
  @spec encode_cursor(struct() | nil, atom()) :: binary() | nil
  def encode_cursor(nil, _time_field), do: nil

  def encode_cursor(record, time_field) do
    case Map.get(record, time_field) do
      %DateTime{} = time ->
        cursor_payload = %{
          "time" => iso8601(time),
          "id" => Map.get(record, :id)
        }

        cursor_payload
        |> Jason.encode!()
        |> Base.url_encode64(padding: false)

      _not_a_time ->
        nil
    end
  end

  # the iso conversion isolated behind a total helper: the record field is
  # dynamically typed, and the boundary keeps the type inference local
  defp iso8601(%DateTime{} = time), do: DateTime.to_iso8601(time)
end
