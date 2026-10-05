defmodule AshHooks.Subscription do
  @moduledoc """
  Turns the consumer's resource into the outbound Subscription — which
  events go to which endpoint, and with which signature envelope.

      use Ash.Resource,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.Subscription]

      subscription do
        endpoint_resource(MyApp.WebhookEndpoint)
      end

  The extension injects: `event_types` (`{:array, :string}`, default
  `[\"*\"]`), `endpoint_id` (uuid — the pk of the `endpoint_resource`), and
  `signing_mode` (`:legacy | :dual | :standard`, NULLABLE — the outbound
  declaration's mode applies when unset: ADR-0002's per-subscription mode).

  ## Typing contract

  Events carry canonical STRING types (`AshHooks.Event` canonicalizes at
  construction). `event_types` rows match by exact string or the bare
  wildcard — `\"*\"` / `:\"*\"` — with entries normalized via `to_string/1`,
  so a consumer-typed register (`{:array, :atom}`, e.g. a closed
  `one_of:` enum) matches identically to the injected string array: same
  wildcard posture, same exact-match semantics, either representation.
  A closed-enum register is declared by REDECLARING the attribute — your
  own `attribute(:event_types, {:array, :atom}, constraints: [...])`
  replaces the injection entirely (`add_new_attribute` stands down), so
  your enum, your `min_length`, and your own default apply; the wildcard
  default `[\"*\"]` is NOT forced on you.

  Matching is exact strings plus the bare wildcard entry, evaluated IN
  MEMORY by the dispatcher after reading through the consumer's primary
  read action — no array-containment SQL, so the semantics are identical
  on every data layer.

  The package injects NO read action and NO read policies: read surfaces
  are the consumer's to open through their own domain policies — the
  dispatcher's internal reads run unauthorized, the inbound reaper's
  precedent (ADR-0005's consumer-governed posture).
  """

  @signing_modes [:legacy, :dual, :standard]

  @doc """
  The subscription-level signing modes: `:legacy` (legacy envelope only),
  `:dual` (legacy + Standard Webhooks), `:standard` (SW only).
  """
  @spec signing_modes() :: list(atom())
  def signing_modes, do: @signing_modes

  @doc """
  Whether a subscription row (`event_types`) matches an event `type` (a
  canonical string): the bare `"*"` entry matches everything; any other
  entry matches exactly — no glob interpretation. Works on any resource
  row carrying the injected `event_types` attribute.

  Entries are normalized before comparing: atoms to strings (a
  consumer-typed register — `{:array, :atom}`, a closed enum — H8), a
  `"*"`/`:"*"` wildcard in either representation. Without the
  normalization an atom-typed register matched NOTHING — zero deliveries,
  no error. An entry that is neither binary nor atom simply does not
  match (total: one exotic row can never abort the fanout).
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
        `endpoint_id` references — the dispatcher loads endpoints through
        it to check `status` and reachability.
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@section],
    transformers: [AshHooks.Subscription.Transformers.AddSubscriptionFields],
    verifiers: [AshHooks.Verifiers.MultitenancyNoBypass]
end
