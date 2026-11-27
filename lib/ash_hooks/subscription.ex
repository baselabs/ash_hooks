defmodule AshHooks.Subscription do
  @moduledoc """
  Turns the consumer's resource into the outbound Subscription, specifying which
  events go to which endpoint, and with which signature envelope.


  <!-- not-run: This subscription fragment requires a host endpoint resource and data layer configuration. -->

      use Ash.Resource,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.Subscription]

      subscription do
        endpoint_resource(MyApp.WebhookEndpoint)
      end

  The extension injects: `event_types` (`{:array, :string}`, default
  `[\"*\"]`), `endpoint_id` (uuid, the sole UUID-storage-compatible primary
  key of the `endpoint_resource`, under any attribute name), and `signing_mode`
  (`:legacy | :dual | :standard`, NULLABLE, with the outbound declaration's mode
  applying when unset). A subscription's own
  primary key follows the same single UUID-storage-compatible contract because
  outbound delivery rows store it in `subscription_id`. UUIDv7 keys satisfy
  this contract. Composite and non-UUID keys fail at DSL compilation with the
  reference column named in the error.

  With `pausable :on`, the extension also injects `paused` (boolean,
  nonnullable, default `false`). The dispatcher skips paused subscriptions
  before creating delivery rows. Existing delivery rows continue to deliver:
  pausing is not cancellation. Applications pause and resume through their own
  ordinary update actions and policies. Opting in requires a migration for
  the `paused` column; the default `:off` adds no attribute or schema requirement.

  ## Typing contract

  Events carry string types. You can declare `event_types` yourself,
  including as an array of strings, atoms or terms. Atom arrays may be open
  or constrained to the host's declared event names. Native `Ash.Type.NewType`
  subtypes of the string, atom and term elements, map and Boolean are supported.
  SQLite supports string and atom arrays, including element NewTypes. Term
  arrays and their element NewTypes are supported on PostgreSQL, ETS and
  Simple; SQLite's JSON array codec cannot carry Term binaries.
  When enabled, `paused` must be non-null. A nullable `event_types` value
  matches nothing. `event_filters`
  may be nullable or non-null; null filters match. Boolean, integer and map
  element arrays cannot carry arbitrary declared event names. These types and
  incompatible overrides fail resource verification. Your declaration replaces the
  generated attribute, including its constraints and default. Atom and string
  entries match the same event names. The bare `"*"` or `:"*"` entry matches
  all event names.

  Matching uses exact names plus the bare wildcard. The dispatcher selects
  candidates through the consumer's primary read action. PostgreSQL and SQLite
  use SQL predicates. The final Elixir guard applies on every data layer.
  Unrecognized storage shapes widen the query and preserve that guard.
  A PostgreSQL GIN index on `event_types`
  speeds type selection. Malformed filter containers never match.

  When `filter_attributes` is nonempty, create and update actions validate
  `event_filters`, including on resources that declare the attribute themselves.
  Use `validate_filters/2` to check stored or imported values before writing them.

  The package injects NO read action and NO read policies: read surfaces
  are the consumer's to open through their own domain policies; internal
  dispatcher reads bypass authorization; application policies govern exposed reads.
  """

  alias Ash.Error.Changes.InvalidAttribute
  alias Spark.Dsl.Extension

  @signing_modes [:legacy, :dual, :standard]

  @doc """
  The subscription-level signing modes: `:legacy` (legacy envelope only),
  `:dual` (legacy + Standard Webhooks), `:standard` (SW only).
  """
  @spec signing_modes() :: list(atom())
  def signing_modes, do: @signing_modes

  @doc """
  Whether a subscription row matches an event `type` (a canonical string):
  the bare `"*"` entry matches everything; any other entry matches exactly,
  with no glob interpretation. Works on any resource row carrying the
  injected `event_types` attribute. Attribute matching is separate:
  `matches_filters?/2`.

  Atom-valued event types are converted to strings before comparison.
  Entries that are neither strings nor atoms do not match.
  """
  @spec matches?(map(), String.t()) :: boolean()
  def matches?(subscription, type) when is_binary(type) and is_map(subscription) do
    types =
      subscription
      |> Map.get(:event_types)
      |> Kernel.||([])
      |> Enum.map(&normalize_type/1)

    "*" in types or type in types
  end

  @doc """
  Checks attribute filters independently of event-type matching. Each
  `event_filters` entry must
  name a declared `filter_attributes` attribute and equal the dispatching
  event's metadata value (list values match any-of). Rows without filters
  match.
  """
  @spec matches_filters?(map(), map()) :: boolean()
  def matches_filters?(subscription, metadata) when is_map(subscription) and is_map(metadata) do
    declared =
      subscription.__struct__
      |> Extension.get_opt([:subscription], :filter_attributes, [])
      |> MapSet.new(&to_string/1)

    case Map.get(subscription, :event_filters) do
      nil ->
        true

      filters when is_map(filters) and not is_struct(filters) ->
        Enum.all?(filters, fn {key, expected} ->
          Map.has_key?(metadata, to_string(key)) and to_string(key) in declared and
            value_matches?(Map.fetch!(metadata, to_string(key)), expected)
        end)

      _not_a_map ->
        false
    end
  end

  defp value_matches?(actual, expected) when is_list(expected),
    do: actual in expected

  defp value_matches?(actual, expected),
    do: actual == expected

  @doc """
  Checks an `event_filters` value against a subscription resource's declared
  `filter_attributes`. Returns `:ok` or an `Ash.Error.Changes.InvalidAttribute`
  error on `:event_filters`.

  Pass `nil` to match all metadata, or a plain map with distinct declared
  names as atom or string keys. Values may be null, booleans, numbers, or
  UTF-8 strings without NUL characters. A nonempty list of these scalars
  matches any member.
  """
  @spec validate_filters(module(), term()) :: :ok | {:error, InvalidAttribute.t()}
  def validate_filters(_resource, nil), do: :ok

  def validate_filters(resource, filters) when is_map(filters) and not is_struct(filters) do
    declared =
      resource
      |> Extension.get_opt([:subscription], :filter_attributes, [])
      |> MapSet.new(&to_string/1)

    Enum.reduce_while(filters, :ok, fn {key, value}, :ok ->
      case filter_error(key, value, filters, declared) do
        nil -> {:cont, :ok}
        reason -> {:halt, invalid_filters("filter key #{inspect(key)} #{reason}")}
      end
    end)
  end

  def validate_filters(_resource, _filters),
    do: invalid_filters("event_filters must be nil or a plain map")

  defp filter_error(key, value, filters, declared) do
    cond do
      not (is_atom(key) or is_binary(key)) ->
        "must be a string or atom"

      to_string(key) not in declared ->
        "is not declared in filter_attributes"

      is_atom(key) and Map.has_key?(filters, to_string(key)) ->
        "has a duplicate string key"

      is_list(value) and not (value != [] and scalar_list?(value)) ->
        "must have a nonempty list of scalars for an any-of filter"

      not is_list(value) and not scalar?(value) ->
        "must have a scalar value (null, boolean, number, or UTF-8 string without NUL)"

      true ->
        nil
    end
  end

  defp scalar_list?([]), do: true
  defp scalar_list?([value | rest]), do: scalar?(value) and scalar_list?(rest)
  defp scalar_list?(_other), do: false

  defp scalar?(value) when is_binary(value),
    do: String.valid?(value) and not String.contains?(value, <<0>>)

  defp scalar?(value), do: is_number(value) or is_boolean(value) or is_nil(value)

  defp invalid_filters(message),
    do: {:error, InvalidAttribute.exception(field: :event_filters, message: message)}

  defp normalize_type(entry) when is_binary(entry), do: entry
  defp normalize_type(entry) when is_atom(entry), do: Atom.to_string(entry)
  # anything else (a map/tuple-typed register entry) is unmatchable, not
  # a raise, preserving the pre-normalization behavior for those rows
  defp normalize_type(_entry), do: :unmatchable_type

  @section %Spark.Dsl.Section{
    name: :subscription,
    describe: """
    Configuration of this resource as the outbound subscription.
    """,
    schema: [
      endpoint_resource: [
        type: :atom,
        required: true,
        doc: """
        The resource module carrying `AshHooks.Endpoint` that
        `endpoint_id` references. The dispatcher loads endpoint records
        through it and calls `AshHooks.Endpoint.enabled?/1` to decide
        whether they receive delivery rows.
        """
      ],
      pausable: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Whether the subscription pause column is injected (default `:off`,
        leaving existing schemas untouched). With `:on`, the extension
        injects `paused` (boolean, nonnullable, default `false`). The
        dispatcher skips paused subscriptions before creating delivery rows;
        existing delivery rows are unaffected. Applications pause and resume
        through ordinary updates of `paused` under their own actions and
        policies. Declaring `:on` requires a migration for the column.
        """
      ],
      filter_attributes: [
        type: {:list, :atom},
        default: [],
        doc: """
        The closed set of EVENT ATTRIBUTE names subscriptions may filter
        on (e.g. `[:order_id, :region]`). Declaring a nonempty list
        injects the `event_filters` column (`:map`, nullable): a
        subscription whose filters all match the dispatching event's
        metadata receives the delivery. Filters are evaluated before any delivery
        row is created. Writes accept `nil` or a plain map with declared keys and
        scalar values or nonempty lists of scalars. See `validate_filters/2` for
        the accepted values. Requires a migration for the column.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [AshHooks.Subscription.Transformers.AddSubscriptionFields],
    verifiers: [
      AshHooks.Verifiers.InjectedAttributes,
      AshHooks.Verifiers.MultitenancyNoBypass,
      AshHooks.Verifiers.OutboundReferences
    ]
end
