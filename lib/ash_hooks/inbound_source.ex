defmodule AshHooks.InboundSource do
  @moduledoc """
  A host-owned resource for inbound webhook keys, provider selection and pause.

  Sources use opaque keys through `AshHooks.Custody`. The host owns the data
  layer, policies and migrations. Source and ledger resources must have the
  same tenancy and non-nullable scope attributes. Provider aliases select
  modules from a compile-time allowlist.

  Lifecycle functions are system writes using `authorize?: false`. Authorize
  callers before invoking them and restrict direct access to injected machine
  actions. Generated disclosures are returned once and must be delivered to
  the sender securely. They are never stored on the source.
  """

  @source %Spark.Dsl.Section{
    name: :inbound_source,
    describe: "An inbound source with custody keys and a durable provider allowlist.",
    schema: [
      ledger: [
        type: :module,
        required: true,
        doc: "The InboundDelivery resource this source feeds."
      ],
      source_attribute: [
        type: :atom,
        default: :source,
        doc: "Attribute holding the inbound declaration name."
      ],
      scope: [
        type: {:list, {:tuple, [:atom, :any, :keyword_list]}},
        default: [],
        doc:
          "Locally declared {name, type, constraints} scope attributes, matching the ledger's scope_identity."
      ],
      providers: [
        type: :keyword_list,
        required: true,
        doc: "Provider alias to module allowlist. Rows store aliases."
      ],
      custodian: [
        type: :module,
        required: true,
        doc: "The AshHooks.Custody implementation. Sources have no byte resolver path."
      ],
      custody_tenant_key: [
        type: :mfa,
        doc: "Canonical custody tenant hook for a tenant type without built-in canonicalization."
      ],
      key_registry: [
        type: :module,
        required: true,
        doc: "KeyRegistry resource on the same transactional data layer, mutate repo and tenancy."
      ],
      max_overlap_seconds: [
        type: :pos_integer,
        doc: "Maximum permitted overlap in seconds, at least the effective default."
      ],
      default_overlap_seconds: [
        type: :non_neg_integer,
        doc: "Default overlap in seconds. Defaults to 86,400; zero is a hard cut."
      ]
    ]
  }

  use Spark.Dsl.Extension,
    sections: [@source],
    transformers: [
      AshHooks.InboundSource.Transformers.AddSourceFields,
      AshHooks.InboundSource.Transformers.AddSourceActions
    ],
    verifiers: [
      AshHooks.InboundSource.Verifiers.Source,
      AshHooks.Verifiers.MultitenancyNoBypass,
      AshHooks.Endpoint.Verifiers.Overlap
    ]
end
