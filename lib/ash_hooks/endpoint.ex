defmodule AshHooks.Endpoint do
  @moduledoc """
  Turns the consumer's resource into the outbound webhook Endpoint — the
  delivery target with its durable circuit-breaker state and its secret
  REFERENCES.

      use Ash.Resource,
        data_layer: AshSqlite.DataLayer,
        extensions: [AshHooks.Endpoint]

      # optional: map the durable enable/disable onto the consumer's OWN
      # switch (e.g. an `active` boolean) instead of the injected `status`
      endpoint do
        status_attribute :active
        enabled_values [true]
        disabled_value false
      end

  The extension injects: `url`, `status` (`:enabled | :disabled` — the
  durable disable the 410 rule and operators flip; an in-process fuse would
  forget, this does not), and the four secret refs (`secret_ref` required,
  `previous_secret_ref` / `legacy_secret_ref` / `legacy_previous_secret_ref`
  for rotation and the legacy envelope). All four are
  `AshHooks.Endpoint.SecretRef` — the TYPE rejects secret-shaped literals
  (`whsec_` / `whsk_` / `whpk_` prefixed material) at cast, on every write
  path including consumer-defined actions: secrets live behind consumer
  callbacks, rows carry only their references (ADR-0005).

  With `status_attribute` set, the injected `status` attribute is NOT
  injected — the consumer's attribute is the ONE durable switch (two
  switches cannot silently disagree), the dispatcher skips endpoints whose
  mapped value is outside `enabled_values`, and the 410 auto-disable flips
  the mapped attribute to `disabled_value`. The mapped attribute must be
  declared by the consumer (fail-closed at compile).

  The dispatcher skips non-enabled endpoints entirely (no delivery row).
  The SSRF guard (scheme/private-range/link-local/metadata checks) runs
  at registration on every write path AND again at send time with DNS
  re-resolution — this resource is its registration substrate.

  Read access is the consumer's to govern: rows carry target URLs and
  secret REFERENCES (never secret material), and the package injects no
  read policies (ADR-0005's consumer-governed posture).

  POLICY OBLIGATION (write side — you write your own policies here too):
  the package injects ONE write action on this resource: `:disable` (the
  durable circuit breaker). The 410 rule drives it as a system bulk write
  (`authorize?: false` by design); a CONSUMER-facing surface that exposes
  it must carry its own action-specific policy — under a permissive base
  fragment any actor could otherwise disable a tenant's endpoints. See
  `AshHooks.OutboundDelivery`'s moduledoc for the delivery ledger's seven.
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
        Map.get(endpoint, attribute) in values
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
        The consumer's OWN enable/disable attribute the package maps onto
        (e.g. `active`). When set, `status` is NOT injected — the mapped
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
        REQUIRED with `status_attribute`: the mapped attribute's values
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
