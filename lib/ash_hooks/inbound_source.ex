defmodule AshHooks.InboundSource do
  @moduledoc """
  A host-owned resource for inbound webhook keys, provider selection and pause.

  Sources use opaque keys through `AshHooks.Custody`. The host owns the data
  layer, policies and migrations. Source and ledger resources must have the
  same tenancy and non-nullable scope attributes. Provider aliases select
  modules from a compile-time allowlist. Each ledger declaration's `source_record`
  must name a source whose `ledger` is that declaring resource.

  The extension injects the following attributes for host migrations:

  * The declaration-name attribute (`:source` by default) is a required atom.
    Each locally declared scope attribute is required. `:provider` is a required
    atom constrained to the allowlist's aliases.
  * `:secret_ref` and `:previous_secret_ref` are nullable opaque reference
    strings. `:secret_kind` and `:previous_secret_kind` are nullable terms.
  * `:public_key` and `:public_key_kind` are nullable terms for pinned sender
    verification material outside custody. Its kind must be one of
    `AshHooks.Custody.PublicKey`'s closed asymmetric kinds, and the material
    must decode under that kind before creation or registration. `:paused` is a required boolean
    defaulting to false.
  * `:secret_created_at`, `:secret_first_used_at`,
    `:previous_secret_created_at`, `:previous_secret_first_used_at` and
    `:previous_secret_retired_at` are nullable microsecond UTC datetimes.

  Without a host primary key, the extension adds a writable UUID `:id` with a
  generated default. The `:unique_source` identity comprises the declaration-name
  attribute and scope attributes, under the resource's tenancy. Host attributes
  with injected names must match their type, constraints and nullability.

  Lifecycle functions are system writes using `authorize?: false`. Authorize
  callers before invoking them and restrict direct access to injected machine
  actions. Generated disclosures are returned once and must be delivered to
  the sender securely. They are never stored on the source.

  Injected machine actions are `:roll_secret`, `:schedule_previous_retirement`,
  `:expire_previous_secret`, `:register_public_key`, `:pause`, `:unpause`,
  `:mark_current_secret_used`, `:mark_previous_secret_used`, `:set_custody_keys`
  and `:read_custody_owner`. Secret-bearing arguments are sensitive. Direct
  kind input is refused on host create and update actions. Direct reference
  input is always refused; use `create_source/3` to issue and attach
  references through the key registry.
  """

  alias AshHooks.Custody.PublicKey
  alias AshHooks.{KeyLifecycle, Keys, Phase, PrimaryKey, Tenancy}
  alias AshHooks.KeyRegistry.Storage

  @doc """
  Creates a source with `material:` and `kind:`, `generate: {:standard_webhooks,
  :v1}`, or a pinned `public_key:` and `kind:`. Optional `previous:` material
  requires `previous_retires_at:`; `previous_kind:` defaults to the current kind.
  Returns `{:ok, source}` or `{:ok, source, disclosure}` for generation.
  Issuing refuses enclosing transactions. Direct reference input is refused.
  Options include `:tenant`, `:action` and the application clock `:now`.
  """
  @spec create_source(module(), map(), keyword()) ::
          {:ok, struct()} | {:ok, struct(), term()} | {:error, term()}
  def create_source(resource, attributes, opts \\ []), do: Keys.create(resource, attributes, opts)

  @doc """
  Rolls the current custody key with sender-issued `material:` and `kind:`,
  or `generate: {:standard_webhooks, :v1}`. Generation returns a one-time
  `whsec_` disclosure. Other generation kinds return `:kind_not_allowed`
  before issuance. Options: `:tenant`, `:now`, and `:overlap_seconds`.
  An active overlap refuses another roll. Expire the previous key first or
  wait for its deadline. Issuing refuses an enclosing transaction.
  """
  @spec roll_secret(struct(), keyword()) ::
          {:ok, struct()} | {:ok, struct(), term()} | {:error, term()}
  def roll_secret(source, opts \\ []), do: Keys.roll(source, opts)

  @doc """
  Generates a replacement current key of the same kind, leaving the previous
  key and its retirement time unchanged. Returns the one-time disclosure.
  Only the symmetric standard v1 kind may be generated; sender-issued kinds
  return `:kind_not_allowed` before issuance. The replaced current key stops
  verifying immediately. Only the separate previous key keeps working until
  its own deadline. Options: `:tenant` and `:now`. Refuses enclosing transactions.
  """
  @spec reissue_secret(struct(), keyword()) :: {:ok, struct(), term()} | {:error, term()}
  def reissue_secret(source, opts \\ []), do: Keys.reissue(source, opts)

  @doc "Sets a previous key's retirement time, fenced on its reference. Options: `:tenant`, `:now`."
  @spec schedule_previous_retirement(struct(), term(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def schedule_previous_retirement(source, at, opts \\ []),
    do: KeyLifecycle.schedule_previous_retirement(source, at, opts)

  @doc "Removes the previous key and retires its custody reference for disposal. Options: `:tenant`, `:now`."
  @spec expire_previous_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def expire_previous_secret(source, opts \\ []),
    do: KeyLifecycle.expire_previous_secret(source, opts)

  @doc "Sweeps dated previous keys whose deadlines have ended. Returns `{:ok, count}`. Options: `:tenant`, `:now`."
  @spec expire_previous_secrets(module(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire_previous_secrets(resource, opts \\ []),
    do: KeyLifecycle.expire_previous_secrets(resource, opts)

  @doc """
  Pins a sender's public verification key outside custody. The required
  `:kind` is one of `AshHooks.Custody.PublicKey`'s asymmetric kinds. Invalid
  kinds or undecodable keys return `KeyKindMismatch` before writing.
  Option: `:tenant`.
  """
  @spec register_public_key(struct(), term(), keyword()) :: {:ok, struct()} | {:error, term()}
  def register_public_key(%resource{} = source, public_key, opts \\ []) do
    with {:ok, _tenant} <- Tenancy.resolve([resource], opts[:tenant]),
         {:ok, _pin} <- PublicKey.new(public_key, opts[:kind]) do
      update(
        source,
        :register_public_key,
        %{public_key: public_key, public_key_kind: opts[:kind]},
        opts
      )
    end
  end

  @doc "Pauses new requests; authenticated receipts remain recoverable. Option: `:tenant`."
  @spec pause(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def pause(source, opts \\ []), do: update(source, :pause, %{}, opts)

  @doc "Resumes new requests. Option: `:tenant`."
  @spec unpause(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def unpause(source, opts \\ []), do: update(source, :unpause, %{}, opts)

  @doc """
  Adopts pre-cutover nil-alias receipts for this source resource's ledger.
  `name` must select a declaration fed by this resource, and `alias` must be
  in its allowlist. `expected_provider:` can pin the old declaration's module.
  Each claim atomically stamps its alias and commits before handling.
  Options: `:tenant`, positive `:limit` (default 100), `:expected_provider`.
  Returns `{:ok, %{driven: count, remaining: count}}`. Remaining includes live
  pre-cutover claims; repeat until it reaches zero. Refuses enclosing transactions
  before reading with `{:error, :inside_transaction}`. Terminal nil-alias rows
  remain unchanged. Returns `{:error, :invalid_limit}` for a nonpositive or
  noninteger limit, `{:error, :source_mismatch}` when the declaration does not
  use this source resource, and `{:error, :provider_mismatch}` for an unknown
  alias or a mismatched `:expected_provider`. Correct the arguments before retrying.
  """
  @spec adopt_provider_alias(module(), atom(), atom(), keyword()) ::
          {:ok, %{driven: non_neg_integer(), remaining: non_neg_integer()}} | {:error, term()}
  def adopt_provider_alias(resource, name, alias, opts \\ []),
    do: AshHooks.Ingress.adopt_provider_alias(resource, name, alias, opts)

  defp update(%resource{} = source, action, input, opts) do
    with {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      Phase.bulk(
        resource |> Storage.owner_query(tenant) |> Ash.Query.do_filter(PrimaryKey.filter(source)),
        tenant,
        &Ash.bulk_update(&1, action, input,
          authorize?: false,
          tenant: tenant,
          strategy: [:atomic],
          return_records?: true,
          return_errors?: true
        )
      )
      |> case do
        %Ash.BulkResult{status: :success, records: [row]} -> {:ok, row}
        %Ash.BulkResult{status: :success, records: []} -> {:error, :rolled_underneath}
        %Ash.BulkResult{errors: [error | _]} -> {:error, error}
      end
    end
  end

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
        doc: """
        KeyRegistry resource with the same transactional data layer and repository
        for writes, and matching attribute tenancy.
        """
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
      AshHooks.Verifiers.InjectedAttributes,
      AshHooks.InboundSource.Verifiers.Source,
      AshHooks.Verifiers.MultitenancyNoBypass,
      AshHooks.Endpoint.Verifiers.Overlap
    ]
end
