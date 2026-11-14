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
  The endpoint lifecycle statuses; `:disabled` is the durable circuit
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

  require Ash.Query

  alias AshHooks.Errors.Unknown.UnknownError
  alias AshHooks.{PrimaryKey, Tenancy}

  @doc """
  Rolls the endpoint's signing secret reference with an overlap window:
  the incumbent reference moves to `previous_secret_ref` and the new reference
  takes its place. Both keys sign while the previous reference remains stored.
  Schedule `expire_previous_secrets/2` to remove expired references; signing
  can continue past the deadline if that sweep is delayed.

      {:ok, rolled} =
        AshHooks.Endpoint.roll_secret(endpoint,
          # your store already holds the new secret under this reference
          new_secret_ref: "acme-2026-11",
          overlap_seconds: 24 * 3_600
        )

  Options: `:new_secret_ref` (required; a fresh store reference; rolling
  onto the incumbent is `{:error, :same_reference}`), `:overlap_seconds`
  (default 86,400), `:now` (the application clock), `:tenant`. Emits
  `[:ash_hooks, :endpoint, :roll]` with the endpoint id. The row carries
  references and lifecycle timestamps only; never secret material. The
  gated write fences concurrent rolls
  (`{:error, :rolled_underneath}` when the incumbent moved first); a
  resource without `key_lifecycle :on` fails with a named error.
  """
  @spec roll_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def roll_secret(endpoint, opts \\ []) do
    resource = endpoint.__struct__

    with {:ok, new_ref} <- validate_new_secret_ref(endpoint, opts[:new_secret_ref]),
         :ok <- require_lifecycle(resource),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      rolled_at = opts[:now] || DateTime.utc_now()
      rolled_at = DateTime.truncate(rolled_at, :microsecond)
      retired_at = DateTime.add(rolled_at, opts[:overlap_seconds] || 86_400, :second)

      result =
        resource
        |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(secret_ref == ^endpoint.secret_ref)
        |> Ash.bulk_update(
          :roll_secret,
          %{
            new_secret_ref: new_ref,
            old_ref: endpoint.secret_ref,
            old_created_at: endpoint.secret_created_at,
            retired_at: retired_at,
            rolled_at: rolled_at
          },
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )

      case result do
        %Ash.BulkResult{status: :success, records: [rolled]} ->
          :telemetry.execute(
            [:ash_hooks, :endpoint, :roll],
            %{},
            %{endpoint_id: PrimaryKey.scalar!(endpoint)}
          )

          {:ok, rolled}

        %Ash.BulkResult{status: :success, records: []} ->
          {:error, :rolled_underneath}

        %Ash.BulkResult{} = result ->
          {:error, List.first(result.errors || []) || result}
      end
    end
  end

  @doc """
  Retires one endpoint's previous signing key at once: the old reference
  leaves the row and its retirement time stands as the record. A row with
  no previous key is returned unchanged.

  `:tenant` applies to the gated write (required on multitenant
  resources; the tenancy pre-flight runs before it).
  """
  @spec expire_previous_secret(struct(), keyword()) :: {:ok, struct()} | {:error, term()}
  def expire_previous_secret(endpoint, opts \\ []) do
    resource = endpoint.__struct__

    with :ok <- require_lifecycle(resource),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      expire_previous_secret_gated(endpoint, tenant)
    end
  end

  defp expire_previous_secret_gated(endpoint, tenant) do
    resource = endpoint.__struct__

    if is_nil(endpoint.previous_secret_ref) do
      {:ok, endpoint}
    else
      result =
        resource
        |> Ash.Query.do_filter(PrimaryKey.filter(endpoint))
        |> Ash.Query.filter(previous_secret_ref == ^endpoint.previous_secret_ref)
        |> Ash.bulk_update(:retire_previous_secret, %{},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )

      case result do
        %Ash.BulkResult{status: :success, records: [retired]} -> {:ok, retired}
        %Ash.BulkResult{status: :success, records: []} -> {:ok, endpoint}
        %Ash.BulkResult{} = result -> {:error, List.first(result.errors || []) || result}
      end
    end
  end

  @doc """
  The scheduled retirement sweep: expires every endpoint whose previous
  key's overlap window has ended (`previous_secret_retired_at <= now`).
  Schedule it alongside your retention sweeps. Signing uses the previous key
  until its reference is removed, even after the scheduled deadline. Returns
  `{:ok, retired_count}`.

  Options: `:now` (the application clock) and `:tenant` (required on
  multitenant resources).
  """
  @spec expire_previous_secrets(module(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def expire_previous_secrets(resource, opts \\ []) do
    now = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.truncate(:microsecond)

    with :ok <- require_lifecycle(resource),
         {:ok, tenant} <- Tenancy.resolve([resource], opts[:tenant]) do
      result =
        resource
        |> Ash.Query.filter(
          not is_nil(previous_secret_ref) and previous_secret_retired_at <= ^now
        )
        |> Ash.bulk_update(:retire_previous_secret, %{},
          authorize?: false,
          return_records?: true,
          return_errors?: true,
          strategy: [:atomic],
          tenant: tenant
        )

      case result do
        %Ash.BulkResult{status: :success, records: records} -> {:ok, length(records)}
        %Ash.BulkResult{} = result -> {:error, List.first(result.errors || []) || result}
      end
    end
  end

  # the warning share defaults to the disable share when unset
  defp warning_share(resource) do
    Extension.get_opt(resource, [:endpoint, :auto_disable], :warning_share, nil) ||
      Extension.get_opt(resource, [:endpoint, :auto_disable], :failure_share, 0.95)
  end

  defp validate_new_secret_ref(endpoint, ref) do
    cond do
      not (is_binary(ref) and ref != "") ->
        {:error, :new_secret_ref_required}

      ref == endpoint.secret_ref ->
        {:error, :same_reference}

      true ->
        {:ok, ref}
    end
  end

  defp require_lifecycle(resource) do
    if lifecycle?(resource) do
      :ok
    else
      {:error, lifecycle_error(resource)}
    end
  end

  defp lifecycle?(resource), do: ResourceInfo.attribute(resource, :secret_created_at) != nil

  defp lifecycle_error(resource) do
    UnknownError.exception(
      error:
        inspect(resource) <>
          " does not carry the key-lifecycle columns (key_lifecycle :off) — " <>
          "declare `key_lifecycle :on` under `endpoint` and migrate the six " <>
          "columns to roll signing secrets"
    )
  end

  @auto_disable %Spark.Dsl.Section{
    name: :auto_disable,
    describe: """
    The sustained-failure auto-disable policy, beside the 410 rule: the
    health sweep (`AshHooks.EndpointHealth.sweep/3`) disables an endpoint
    whose trailing failure window meets the configured failure share with
    at least `min_attempts` of evidence; only on the sweep AFTER one
    that warned (the declaration injects the `disable_warned_at` marker
    column the warning sweep stamps; migrate it with the declaration).
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
        must be spelled out explicitly; fail-closed at compile.
        """
      ],
      version_pinning: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Whether the payload-version pinning column is injected (default
        `:off`; existing schemas stay untouched). With `:on`, the
        extension injects `pinned_payload_version` (integer, nullable):
        an endpoint pinning a version its event's declaration carries (in
        `payload_versions`) receives THAT variant builder's bytes instead
        of the dispatch payload; a pin on an undeclared version fails the
        endpoint closed at dispatch. Declaring `:on` requires a migration
        for the column.
        """
      ],
      key_lifecycle: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Whether the signing-key lifecycle columns are injected (default
        `:off`; existing schemas stay untouched). With `:on`, the
        extension injects `secret_created_at`, `secret_first_used_at`,
        `secret_retired_at`, `previous_secret_created_at`,
        `previous_secret_first_used_at`, and `previous_secret_retired_at`
        (the scheduled retirement time of the previous key). Removing the
        previous reference does not update that timestamp to the actual removal
        time. `roll_secret/2`, `expire_previous_secret/2` (one endpoint), and
        `expire_previous_secrets/2` (a resource) accept optional arguments.
        Declaring `:on`
        requires a migration for the six columns. Timestamps only; never
        secret material.
        """
      ],
      response_capture_attributes: [
        type: {:in, [:off, :on]},
        default: :off,
        doc: """
        Whether the per-endpoint response-capture columns are injected
        (default `:off`; existing schemas stay untouched). With `:on`,
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
        match nothing; zero deliveries, no error; so the mapping
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
    do: {:error, "must be a number in (0, 1] — a share of the window's attempts"}

  @doc """
  The resolved auto-disable policy for an endpoint resource, or nil when
  the resource declares no `auto_disable` section: a map with
  `:failure_window_seconds`, `:failure_share`, `:min_attempts`,
  `:warning_share`, and `:warning_min_attempts` (defaults applied).
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
    verifiers: [AshHooks.Verifiers.MultitenancyNoBypass]
end
