defmodule AshHooks.Subscription do
  @moduledoc """
  Turns the consumer's resource into the outbound Subscription, specifying which
  events go to which endpoint, and with which signature envelope.

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
  including as an array of constrained atoms. Your declaration replaces the
  generated attribute, including its constraints and default. Atom and string
  entries match the same event names. The bare `"*"` or `:"*"` entry matches
  all event names.

  Matching is exact strings plus the bare wildcard entry, evaluated IN
  MEMORY by the dispatcher after reading through the consumer's primary
  read action. There is no array-containment SQL, so the semantics are identical
  on every data layer.

  The package injects NO read action and NO read policies: read surfaces
  are the consumer's to open through their own domain policies; internal
  dispatcher reads bypass authorization; application policies govern exposed reads.
  """

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
  injected `event_types` attribute. The attribute-filter leg is separate:
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
  The FILTER leg of matching, on its own: every `event_filters` entry must
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

    subscription
    |> Map.get(:event_filters)
    |> case do
      nil -> %{}
      filters when is_map(filters) -> filters
      _not_a_map -> %{__invalid__: true}
    end
    |> Enum.all?(fn {key, expected} ->
      Map.has_key?(metadata, to_string(key)) and to_string(key) in declared and
        value_matches?(Map.fetch!(metadata, to_string(key)), expected)
    end)
  end

  defp value_matches?(actual, expected) when is_list(expected),
    do: actual in expected

  defp value_matches?(actual, expected),
    do: actual == expected

  defp normalize_type(entry) when is_binary(entry), do: entry
  defp normalize_type(entry) when is_atom(entry), do: Atom.to_string(entry)
  # anything else (a map/tuple-typed register entry) is unmatchable, not
  # a raise — the pre-normalization behavior for those rows
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
        metadata receives the delivery. Filters are evaluated BEFORE any delivery row
        is created. A filter key outside this set never matches (fail
        closed); a list value matches any-of. Requires a migration for the
        column.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [AshHooks.Subscription.Transformers.AddSubscriptionFields],
    verifiers: [
      AshHooks.Verifiers.MultitenancyNoBypass,
      AshHooks.Verifiers.OutboundReferences
    ]
end
