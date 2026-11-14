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

  With `key_lifecycle :on`, a standard previous key signs only before its
  `previous_secret_retired_at`, even if the retirement sweep is delayed.
  A roll inside an active overlap returns `{:error, :overlap_active}`;
  use `expire_previous_secret/2` before rolling again immediately. An ended
  window permits rolling before the sweep. `default_overlap_seconds`
  configures the overlap (86,400 seconds when unset), and optional
  `max_overlap_seconds` caps both rolling and retirement scheduling from now.
  A stored previous reference without a retirement time is an undated state:
  it keeps signing, the sweep skips it, and `roll_secret/2` refuses it with
  `{:error, :previous_secret_undated}`. Resolve it with
  `schedule_previous_retirement/3` or `expire_previous_secret/2`. No retirement
  date is inferred when lifecycle tracking is adopted. Without lifecycle
  tracking, previous keys keep signing until their references are removed.

  With `legacy_key_lifecycle :on` (requires `key_lifecycle :on`), the legacy
  slot follows the same lifecycle. Migrate its five nullable timestamps:
  `legacy_secret_created_at`, `legacy_secret_first_used_at`,
  `legacy_previous_secret_created_at`, `legacy_previous_secret_first_used_at`,
  and `legacy_previous_secret_retired_at`. The actions
  `:mark_legacy_current_secret_used` and `:mark_legacy_previous_secret_used`
  record first use with the same reference fence. The lifecycle helpers
  accept `slot: :standard | :legacy`, defaulting to `:standard`, and operate
  only on the selected slot. Overlap defaults and caps apply to both slots.
  An empty legacy incumbent installs the new key without a previous key.
  With the legacy option off, no legacy timestamps or actions are injected.

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

  The lifecycle helpers perform system writes (`authorize?: false`) after
  checking tenancy. Authorize application callers before exposing rolling,
  retirement scheduling, or immediate retirement to them.

  With `custodian Module`, declare `key_registry Resource` and
  `key_lifecycle :on`. The registry uses `AshHooks.KeyRegistry`, the same
  transactional AshPostgres or AshSqlite data layer, mutate repo and tenancy.
  Migrate nullable `:term` columns `secret_kind` and `previous_secret_kind`;
  with legacy lifecycle also migrate `legacy_secret_kind` and
  `legacy_previous_secret_kind`. Each kind marks only its adjacent reference
  as custody-owned. A null kind leaves the slot under its host byte resolver.
  Rolling moves kinds with their references. Expiration and ended-window
  displacement retire custody references in the owner's transaction; the
  separately scheduled registry sweep destroys them after commit. See
  `AshHooks.KeyRegistry` and the migration instructions in UPGRADING.md.

  Custody owners also receive the reserved `read_custody_owner` system action.
  It has no action filter, preparation or pagination; the resource's own
  `base_filter` still applies. Lifecycle retirement reads the persisted owner
  after the write and retains references held in any slot. A refusal before
  a write leaves an enclosing host transaction usable. A failure after a
  package write rolls back that write and its registry retirement together.
  """

  @statuses [:enabled, :disabled]

  @doc """
  The endpoint lifecycle statuses: `:disabled` is the durable circuit
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

  @doc """
  Rolls the selected signing slot with an overlap window. The incumbent
  reference moves to that slot's previous reference and the new reference
  takes its place. Both keys sign before the previous key's retirement time;
  at that instant, signing stops using the previous key independently of
  `expire_previous_secrets/2`, which removes expired references.

  A dated previous key still inside its window refuses the roll with
  `{:error, :overlap_active}`. Call `expire_previous_secret/2` before rolling
  again immediately, or wait for the window to end. An ended but unswept
  window does not block rolling.

  An undated previous reference refuses the roll with
  `{:error, :previous_secret_undated}`. Schedule its retirement with
  `schedule_previous_retirement/3` or remove it with `expire_previous_secret/2`
  before rolling.

      {:ok, rolled} =
        AshHooks.Endpoint.roll_secret(endpoint,
          # your store already holds the new secret under this reference
          new_secret_ref: "signing-key-2026-11",
          overlap_seconds: 24 * 3_600
        )

  Options: `:new_secret_ref` (required, a fresh store reference; rolling
  onto the selected incumbent or previous reference is `{:error, :same_reference}`),
  `:slot` (`:standard` by default, or `:legacy` with `legacy_key_lifecycle :on`),
  `:overlap_seconds`
  (a non-negative integer, defaulting to the resource's
  `default_overlap_seconds` or 86,400 when unset), `:now` (the application
  clock), `:tenant`. A negative or non-integer overlap returns
  `{:error, :invalid_overlap}`. Zero stops the old key signing at the roll
  instant. Above the resource's optional `max_overlap_seconds`, rolling
  returns `{:error, {:overlap_exceeds_max, max}}`. Emits
  `[:ash_hooks, :endpoint, :roll]` with the endpoint id. The row carries
  references and lifecycle timestamps only, never secret material. The
  gated write fences concurrent rolls
  (`{:error, :rolled_underneath}` when the incumbent moved first); a
  resource without `key_lifecycle :on` fails with a named error.
  """
  @spec roll_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def roll_secret(endpoint, opts \\ []) do
    AshHooks.KeyLifecycle.roll_secret(endpoint, opts)
  end

  @doc """
  Sets the selected previous key's retirement time, including for an undated
  previous reference adopted with lifecycle tracking. The key signs only
  before that time; the sweep can remove its reference afterward.

  `at` must be a `DateTime` at or after the application clock. A past time
  returns `{:error, :retirement_in_past}`, an invalid value returns
  `{:error, :invalid_retirement_time}`, and an endpoint without a previous
  reference returns `{:error, :no_previous_secret}`. The atomic write checks
  that the previous reference is still the one supplied; a concurrent change
  returns `{:error, :previous_secret_changed}`.

  If the resource declares `max_overlap_seconds`, a retirement time beyond
  that many seconds from now returns `{:error, {:overlap_exceeds_max, max}}`.

  Options: `:slot` (`:standard` by default, or `:legacy` with
  `legacy_key_lifecycle :on`), `:now` (the application clock, default UTC now),
  and `:tenant`
  (required on multitenant resources). Requires `key_lifecycle :on`.
  Authorize the caller before invoking this system write.
  """
  @spec schedule_previous_retirement(struct(), term(), keyword()) ::
          {:ok, struct()} | {:error, term()}
  def schedule_previous_retirement(endpoint, at, opts \\ []) do
    AshHooks.KeyLifecycle.schedule_previous_retirement(endpoint, at, opts)
  end

  @doc """
  Retires one endpoint's selected previous signing key at once: the old
  reference leaves the row and its retirement timestamp records the actual retirement
  time, including early removal. A row with no previous key is returned unchanged.
  This also resolves an undated previous reference without assigning it an
  overlap window.

  `:slot` selects `:standard` (default) or `:legacy` (requires
  `legacy_key_lifecycle :on`). `:now` supplies the application clock (default UTC now).
  `:tenant` applies to the gated write (required on multitenant
  resources; the tenancy pre-flight runs before it).
  """
  @spec expire_previous_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def expire_previous_secret(endpoint, opts \\ []) do
    AshHooks.KeyLifecycle.expire_previous_secret(endpoint, opts)
  end

  @doc """
  The scheduled retirement sweep: expires every endpoint whose selected
  previous key's overlap window has ended (retirement time at or before now).
  Schedule it alongside your retention sweeps. Signing already omits dated
  previous keys at their deadline. Undated previous references are skipped;
  resolve them with `schedule_previous_retirement/3` or
  `expire_previous_secret/2`. Returns `{:ok, retired_count}`.

  Options: `:slot` (`:standard` by default, or `:legacy` with
  `legacy_key_lifecycle :on`), `:now` (the application clock), and `:tenant` (required on
  multitenant resources).
  """
  @spec expire_previous_secrets(module(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire_previous_secrets(resource, opts \\ []) do
    AshHooks.KeyLifecycle.expire_previous_secrets(resource, opts)
  end

  # the warning share defaults to the disable share when unset
  defp warning_share(resource) do
    Extension.get_opt(resource, [:endpoint, :auto_disable], :warning_share, nil) ||
      Extension.get_opt(resource, [:endpoint, :auto_disable], :failure_share, 0.95)
  end

  @auto_disable %Spark.Dsl.Section{
    name: :auto_disable,
    describe: """
    The sustained-failure auto-disable policy, beside the 410 rule: the
    health sweep (`AshHooks.EndpointHealth.sweep/3`) disables an endpoint
    whose trailing failure window meets the configured failure share with
    at least `min_attempts` of evidence, after one full `warning_interval_seconds`
    (default 60) from the stored warning time. The declaration injects the
    `disable_warned_at` marker column; migrate it with the declaration.
    Recovery below the warning band clears the marker. Re-enabling is an
    explicit application action.
    """,
    schema: [
      failure_window_seconds: [
        type: :pos_integer,
        default: 3_600,
        doc: "The trailing window the failure share is computed over."
      ],
      failure_share: [
        type: {:custom, AshHooks.Endpoint, :validate_share, []},
        default: 0.95,
        doc: """
        The failed-attempt share (0 < share <= 1) at or above which the
        window counts as sustained failure.
        """
      ],
      min_attempts: [
        type: :pos_integer,
        default: 10,
        doc: "Minimum attempts in the window before the policy may disable."
      ],
      warning_interval_seconds: [
        type: :pos_integer,
        default: 60,
        doc: "Minimum seconds after the warning marker before sustained failure can disable."
      ],
      warning_share: [
        type: {:custom, AshHooks.Endpoint, :validate_share, []},
        doc: """
        The warning threshold's failure share (default: `failure_share`).
        """
      ],
      warning_min_attempts: [
        type: :pos_integer,
        doc: """
        Minimum attempts before a warning fires (default: half of
        `min_attempts`, at least 1).
        """
      ]
    ]
  }

  @status_section %Spark.Dsl.Section{
    name: :endpoint,
    sections: [@auto_disable],
    describe: """
    Configuration of this resource as the outbound webhook endpoint.
    """,
    schema: [
      custodian: [
        type: :module,
        doc:
          "Opaque-key custodian implementing AshHooks.Custody. Requires key_lifecycle :on and key_registry. Injects a kind marker beside each enabled signing slot's reference; migrate these columns before enabling."
      ],
      key_registry: [
        type: :module,
        doc:
          "Host resource using AshHooks.KeyRegistry, on the same transactional AshPostgres or AshSqlite data layer, mutate repo and tenancy as this endpoint."
      ],
      status_attribute: [
        type: :atom,
        doc: """
        The consumer's enable/disable attribute the package maps onto
        (e.g. `active`). When set, `status` is not injected; the mapped
        attribute is the one durable switch: the dispatcher skips
        endpoints whose value is outside `enabled_values`, and the 410
        auto-disable sets it to `disabled_value`. The attribute must be
        declared in the resource's own `attributes` block (not another
        extension's injection), and `enabled_values`/`disabled_value`
        must be spelled out explicitly, or compilation fails closed.
        """
      ],
      version_pinning: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Whether the payload-version pinning column is injected (default
        `:off`, leaving existing schemas untouched). With `:on`, the
        extension injects `pinned_payload_version` (integer, nullable).
        Endpoints without a pin, or pinned to the declaration's current
        `version`, receive the dispatch payload. Other pins select the
        matching `payload_versions` builder; a pin on a version with no
        builder fails that endpoint closed at dispatch, before any row is
        written. Declaring `:on` requires a migration
        for the column.
        """
      ],
      key_lifecycle: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Whether the signing-key lifecycle columns are injected (default
        `:off`, leaving existing schemas untouched). With `:on`, the
        extension injects `secret_created_at`, `secret_first_used_at`,
        `secret_retired_at`, `previous_secret_created_at`,
        `previous_secret_first_used_at`, and `previous_secret_retired_at`
        (the scheduled deadline while the previous reference remains, then the
        actual retirement time when the reference is removed). Signing omits
        the standard previous key at its deadline, before the sweep removes
        its reference. An undated previous key keeps signing and blocks
        rolling until `schedule_previous_retirement/3` or
        `expire_previous_secret/2` resolves it; the sweep skips it.
        An active overlap refuses another roll with `:overlap_active`;
        expire the previous key before rolling again immediately, or wait
        for the window to end. An ended window permits rolling before the sweep.
        `roll_secret/2`, `schedule_previous_retirement/3`,
        `expire_previous_secret/2` (one endpoint), and
        `expire_previous_secrets/2` (a resource) accept optional arguments.
        Declaring `:on`
        requires a migration for the six columns. Timestamps only, never
        secret material.
        """
      ],
      legacy_key_lifecycle: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Opts the legacy signing slot into the same lifecycle as standard keys.
        Requires `key_lifecycle :on`. Injects five nullable `utc_datetime_usec`
        columns: `legacy_secret_created_at`, `legacy_secret_first_used_at`,
        `legacy_previous_secret_created_at`, `legacy_previous_secret_first_used_at`,
        and `legacy_previous_secret_retired_at`. Migrate these columns before
        enabling. Lifecycle helpers accept `slot: :legacy`; the default remains
        `slot: :standard`. The same overlap gate, defaults, caps, retirement
        scheduling, sweep, and fenced first-use stamps apply to each slot.
        Signing omits a dated legacy previous key at its retirement instant.
        """
      ],
      max_overlap_seconds: [
        type: :pos_integer,
        doc: """
        Optional maximum overlap for each enabled signing slot, in seconds.
        `roll_secret/2` refuses a longer overlap with
        `{:error, {:overlap_exceeds_max, max}}`. Retirement scheduling
        refuses a deadline beyond that many seconds from the application
        clock. Must be at least the effective `default_overlap_seconds`.
        """
      ],
      default_overlap_seconds: [
        type: :non_neg_integer,
        doc: """
        Default overlap for each enabled signing slot in seconds when `roll_secret/2`
        receives no `:overlap_seconds`. If unset, the default is 86,400.
        Zero stops the old key signing at the roll instant. Must not exceed
        `max_overlap_seconds` when a maximum is configured.
        """
      ],
      response_capture_attributes: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Whether the per-endpoint response-capture columns are injected
        (default `:off`, leaving existing schemas untouched). With `:on`,
        the extension injects `response_capture` (boolean, default
        `false`), `response_capture_max_bytes` (integer, default 2048),
        `response_capture_retention_seconds` (integer, default 30 days),
        and `response_header_allowlist` (string array, default none).
        Capture is still per ROW: an endpoint records response bodies in
        its attempt history only when its `response_capture` value is
        `true`. The captured bytes are bounded by the row's cap, pass the
        package's redaction floor, and only allowlisted response header
        names are kept. Declaring `:on` requires a migration for the four
        new columns.
        """
      ],
      enabled_values: [
        type: {:list, :any},
        doc: """
        Required with `status_attribute`: the mapped attribute's values
        that make the endpoint deliverable (e.g. `[true]`). A defaulted
        list against a boolean or custom-enum switch would silently
        match nothing (zero deliveries, no error), so the mapping
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

  @doc false
  def validate_share(share) when is_number(share) and share > 0 and share <= 1,
    do: {:ok, share}

  def validate_share(_invalid),
    do: {:error, "must be a number in (0, 1]: a share of the window's attempts"}

  @doc """
  The resolved auto-disable policy for an endpoint resource, or nil when
  the resource declares no `auto_disable` section: a map with
  `:failure_window_seconds`, `:failure_share`, `:min_attempts`,
  `:warning_share`, `:warning_min_attempts`, and `:warning_interval_seconds`
  (defaults applied).
  """
  @spec auto_disable_policy(module()) :: map() | nil
  def auto_disable_policy(resource) do
    alias Spark.Dsl.Extension

    if Extension.get_opt(resource, [:endpoint, :auto_disable], :failure_share, :__missing__) !=
         :__missing__ do
      %{
        failure_window_seconds:
          Extension.get_opt(resource, [:endpoint, :auto_disable], :failure_window_seconds, 3_600),
        failure_share:
          Extension.get_opt(resource, [:endpoint, :auto_disable], :failure_share, 0.95),
        min_attempts: Extension.get_opt(resource, [:endpoint, :auto_disable], :min_attempts, 10),
        warning_interval_seconds:
          Extension.get_opt(resource, [:endpoint, :auto_disable], :warning_interval_seconds, 60),
        warning_share: warning_share(resource),
        warning_min_attempts:
          Extension.get_opt(resource, [:endpoint, :auto_disable], :warning_min_attempts, nil) ||
            max(
              div(Extension.get_opt(resource, [:endpoint, :auto_disable], :min_attempts, 10), 2),
              1
            )
      }
    end
  end

  use Spark.Dsl.Extension,
    sections: [@status_section],
    transformers: [
      AshHooks.Endpoint.Transformers.AddEndpointFields,
      AshHooks.Endpoint.Transformers.AddEndpointActions
    ],
    verifiers: [
      AshHooks.Endpoint.Verifiers.Custody,
      AshHooks.Endpoint.Verifiers.Overlap,
      AshHooks.Endpoint.Verifiers.LegacyLifecycle,
      AshHooks.Verifiers.MultitenancyNoBypass
    ]
end
