defmodule AshHooks.Endpoint do
  alias Ash.Resource.Info, as: ResourceInfo

  @moduledoc """
  Configures an Ash resource as an outbound webhook destination, including
  its enable/disable state and references to signing secrets.

      use Ash.Resource,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.Endpoint]

      # Map a declared :active boolean instead of injecting :status.
      endpoint do
        status_attribute :active
        enabled_values [true]
        disabled_value false
      end

  The extension injects `url`, `status` (`:enabled | :disabled`), and four
  secret references (`secret_ref` required,
  `previous_secret_ref` / `legacy_secret_ref` / `legacy_previous_secret_ref`
  for rotation and the legacy envelope). All four are
  `AshHooks.Endpoint.SecretRef`. The type rejects secret-shaped literals
  (`whsec_` / `whsk_` / `whpk_` prefixed material) at cast, on every write
  path including consumer-defined actions: secrets live behind consumer
  callbacks; store references to those secrets in the endpoint rows.

  With `status_attribute` set, the extension uses that attribute instead of
  injecting `status`. The dispatcher skips endpoints whose
  mapped value is outside `enabled_values`, and the 410 auto-disable flips
  the mapped attribute to `disabled_value`. The mapped attribute must be
  declared by the consumer (fail-closed at compile).

  The dispatcher skips non-enabled endpoints entirely (no delivery row).
  URL casting checks the scheme, metadata hostnames, and literal IP addresses
  on every write path. Send-time validation resolves hostnames and rejects
  nonpublic addresses; the HTTP adapter pins the validated connection address.

  Govern read access to target URLs and secret references with your own
  resource policies. The package does not inject read policies.

  Policy obligation: protect the injected `:disable` action wherever you
  expose it to application callers. The 410 rule uses it as a system write
  (`authorize?: false`). A permissive resource policy can otherwise allow
  callers to disable endpoints. See `AshHooks.OutboundDelivery` for the
  delivery ledger's action policy requirements.
  """

  @statuses [:enabled, :disabled]

  @doc """
  The endpoint lifecycle statuses — `:disabled` is the durable circuit
  breaker the 410 rule and operators flip.
  """
  @spec statuses() :: list(atom())
  def statuses, do: @statuses

  @doc """
  Whether an endpoint row is deliverable under its configured status
  source: the injected `status` attribute (default) or the consumer-owned
  `status_attribute` mapping (`enabled_values` / `disabled_value`). The
  dispatcher's skip decision and the send path's dead-letter decision
  both route through here, so exactly one switch governs delivery.
  """
  alias Spark.Dsl.Extension

  @spec enabled?(map()) :: boolean()
  def enabled?(endpoint) do
    resource = endpoint.__struct__

    case Extension.get_opt(resource, [:endpoint], :status_attribute, nil) do
      nil ->
        Map.get(endpoint, :status) == :enabled

      attribute ->
        values = Extension.get_opt(resource, [:endpoint], :enabled_values, [:enabled])
        definition = ResourceInfo.attribute(resource, attribute)

        Enum.any?(values, fn enabled ->
          Ash.Type.equal?(
            definition.type,
            Map.get(endpoint, attribute),
            enabled,
            definition.constraints
          )
        end)
    end
  end

  @status_section %Spark.Dsl.Section{
    name: :endpoint,
    describe: """
    Configuration of this resource as the outbound webhook endpoint.
    """,
    schema: [
      status_attribute: [
        type: :atom,
        doc: """
        The consumer's enable/disable attribute the package maps onto
        (e.g. `active`). When set, `status` is not injected — the mapped
        attribute is the one durable switch: the dispatcher skips
        endpoints whose value is outside `enabled_values`, and the 410
        auto-disable sets it to `disabled_value`. The attribute must be
        declared in the resource's own `attributes` block (not another
        extension's injection), and `enabled_values`/`disabled_value`
        must be spelled out explicitly — fail-closed at compile.
        """
      ],
      enabled_values: [
        type: {:list, :any},
        doc: """
        Required with `status_attribute`: the mapped attribute's values
        that make the endpoint deliverable (e.g. `[true]`). A defaulted
        list against a boolean or custom-enum switch would silently
        match nothing — zero deliveries, no error — so the mapping
        refuses to compile without it.
        """
      ],
      disabled_value: [
        type: :any,
        doc: """
        REQUIRED with `status_attribute`: the value the injected
        `:disable` action (and the 410 auto-disable) writes to the
        mapped attribute (e.g. `false`).
        """
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@status_section],
    transformers: [
      AshHooks.Endpoint.Transformers.AddEndpointFields,
      AshHooks.Endpoint.Transformers.AddEndpointActions
    ],
    verifiers: [AshHooks.Verifiers.MultitenancyNoBypass]
end
