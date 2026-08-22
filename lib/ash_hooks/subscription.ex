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

  Matching is exact strings plus the bare `\"*\"` entry, evaluated IN
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
  """
  @spec matches?(map(), String.t()) :: boolean()
  def matches?(subscription, type) when is_binary(type) and is_map(subscription) do
    types = Map.get(subscription, :event_types) || []

    "*" in types or type in types
  end

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
    verifiers: []
end
