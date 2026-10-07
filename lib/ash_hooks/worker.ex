defmodule AshHooks.Worker do
  @moduledoc """
  The host-injected Oban worker (ADR-0004): the consuming app defines one
  module, and the Oban beam compiles only where Oban exists. This macro
  expands `use Oban.Worker` inside the host's compilation, so the package
  itself never references a loaded Oban module and compiles Oban-free
  (the CI no-optional leg's proof).

      defmodule MyApp.WebhookDeliveryWorker do
        use AshHooks.Worker,
          deliveries: MyApp.OutboundDelivery,
          endpoints: MyApp.WebhookEndpoint,
          secret_resolver: {MyApp.Secrets, :webhook_secret},
          queue: :webhooks,
          oban: MyApp.Oban
      end

  Consumers pass `enqueue: {MyApp.WebhookDeliveryWorker, :enqueue}` to
  `AshHooks.dispatch/4`; the generated `enqueue/2` is that seam.

  Options:

    * `:deliveries`, `:endpoints` (required) — the consumer's resource
      modules carrying the `AshHooks.OutboundDelivery` / `AshHooks.Endpoint`
      extensions.
    * `:secret_resolver` (required, `{m, f}`) — resolves an endpoint's
      secret reference: `f(ref) :: {:ok, secret_binary} | {:error, term}`.
      The returned value signs the Standard Webhooks envelope
      (its `whsk_`/`whsec_` prefix only selects the key slot for
      rotation); legacy envelopes, when the signing mode uses them, are
      signed from the endpoint's `legacy_secret_ref` /
      `legacy_previous_secret_ref` references through this same resolver.
    * `:tenant_aware_secrets` (optional, default `false`) — switches the
      resolver contract to 2-arity: `f(ref, tenant)`. The tenant is the
      run's args-threaded tenant (the delivery row's tenant, serialized at
      enqueue). Explicit, no arity magic: the default 1-arity contract is
      unchanged.
    * `:snippet_redactor` (`{m, f}`, optional) — a consumer callback run
      on the raw captured body ahead of the package's snippet floor
      (domain-specific tokens need raw input). Only consulted on per-call
      `snippet_capture: true` diagnostic runs; a crash or invalid return
      degrades to the sanitized summary, never raw bytes. The capture
      flag itself is deliberately not a macro option (ADR-0005's snippet
      amendment: compile-time knobs are broad and quiet) — pass it in the
      `AshHooks.Delivery.run/2` config for a one-row diagnostic re-drive.
    * `:http` — the `AshHooks.Http` adapter (default `AshHooks.Http.Bounded`).
    * `:http_opts` — adapter options as a literal keyword list or a
      `{module, function, args}` callback resolved inside each job's monitored
      delivery deadline.
    * `:oban` — the Oban instance name (default the unnamed instance).
    * `:queue` (default `:ash_hooks`), `:timeout` (35,000 ms), and
      `:max_attempts` (20) — Oban Worker options. The job timeout must be
      greater than `:attempt_timeout + :finalization_allowance`.
    * `:attempt_timeout` (25,000 ms) and `:finalization_allowance` (5,000 ms)
      — the driver deadline and extra send-lease interval. The attempt budget
      includes endpoint lookup, secret resolution, signing, destination and
      DNS checks, HTTP, and result persistence. Keep application clocks
      synchronized because lease comparisons use the application clock.
    * `:delivery_max_attempts` (default 10), `:base_backoff_seconds` (2),
      `:max_backoff_seconds` (3600), `:retry_after_cap_seconds` (86_400) —
      the row-driven retry policy. For direct `AshHooks.Delivery.run/2` calls,
      `:delivery_max_attempts` becomes `:max_attempts`; the other retry option
      names and defaults are unchanged. Omitted or `nil` retry options use
      these defaults. The `Retry-After` cap is
      receiver-held-state budget: a receiver returning a large
      `Retry-After` holds its delivery row and its Oban job for up to the
      cap per attempt (the 86,400 default = up to 24 hours per attempt on
      one header; a receiver honoring `Retry-After` deliberately asks for
      exactly that). Lower the cap when the chosen posture is
      exhaust-fast (a wedged receiver dead-letters at the ceiling instead
      of holding state). The cap clamps `Retry-After`; it does not alter the
      backoff ladder.

  The generated enqueue uses `fields: [:args]` with the complete delivery
  key, delivery and endpoint resource names, source, route, endpoint/event,
  and tenant keys. Uniqueness has an infinite period over runnable states
  (`available`, `scheduled`, `executing`, and `retryable`). Completed,
  canceled, and discarded jobs therefore permit a later recovery trigger.
  Enqueue succeeds only after Oban returns a persisted runnable job whose
  identity args match the request. Oban.Basic may briefly report a uniqueness
  conflict without the winning job's ID while its advisory-lock peer commits;
  the generated path retries that result for at most twenty 5 ms waits, then
  returns `{:error, :job_not_persisted}`. Before insertion it binds a deferred
  route once with a compare-and-set update; a different stored route returns
  `{:error, :dispatch_route_conflict}`.
  On multitenant deliveries the enqueue also serializes the row's tenant
  into job args (the attribute value inverted through the resource's
  `tenant_from_attribute`, so `Delivery.run/2`'s forward
  `parse_attribute` round-trips for non-identity parsers too); the
  uniqueness identity includes the serialized tenant. The
  tenant must round-trip Oban's JSON encoding — string tenants (uuids,
  slugs) are the supported shape; adopters with a custom `parse_attribute`
  pair it with `tenant_from_attribute` (the default inverse is identity).
  """

  require Ash.Query

  defp maybe_expand(nil, _expand), do: nil
  defp maybe_expand(value, expand), do: expand.(value)

  defp validate_redactor(m, f) when is_atom(m) and is_atom(f), do: {m, f}

  defp validate_redactor(m, f), do: raise(ArgumentError, redactor_error(m, f))

  defp redactor_error(m, f) do
    "AshHooks.Worker :snippet_redactor must be {module, function} " <>
      "(a 1-arity fn is accepted in the delivery config) — got {#{inspect(m)}, #{inspect(f)}}"
  end

  alias Ash.Resource.Info, as: ResourceInfo

  @doc false
  def bind_route(delivery, route, tenant) do
    unbound_route = AshHooks.OutboundBinding.unbound_route()

    case delivery.dispatch_route do
      ^route ->
        {:ok, delivery}

      ^unbound_route ->
        bind_unbound_route(delivery, route, tenant, unbound_route)

      _other ->
        {:error, :dispatch_route_conflict}
    end
  end

  defp bind_unbound_route(delivery, route, tenant, unbound_route) do
    delivery.__struct__
    |> Ash.Query.do_filter(AshHooks.PrimaryKey.filter(delivery))
    |> Ash.Query.filter(dispatch_route == ^unbound_route)
    |> Ash.bulk_update(:bind_dispatch_route, %{dispatch_route: route},
      authorize?: false,
      return_records?: true,
      return_errors?: true,
      strategy: [:atomic],
      tenant: tenant
    )
    |> bind_route_result(delivery, route, tenant)
  end

  defp bind_route_result(%Ash.BulkResult{} = result, delivery, route, tenant) do
    cond do
      result.status == :success and match?([_], result.records) ->
        {:ok, hd(result.records)}

      result.status == :success and result.records == [] ->
        reload_bound_route(delivery, route, tenant)

      true ->
        {:error, List.first(result.errors || []) || result}
    end
  end

  defp reload_bound_route(delivery, route, tenant) do
    with {:ok, updated} <-
           delivery.__struct__
           |> Ash.Query.do_filter(AshHooks.PrimaryKey.filter(delivery))
           |> Ash.read_one(authorize?: false, tenant: tenant) do
      case updated do
        %{dispatch_route: ^route} -> {:ok, updated}
        _ -> {:error, :dispatch_route_conflict}
      end
    end
  end

  defmacro __using__(opts) do
    # resolved at macro time — `use Oban.Worker` needs literal options,
    # and the config is baked into the host module as a compile-time term.
    # Module-valued options arrive as alias AST; expand them against the
    # CALLER so the baked config holds modules, not quoted aliases.
    caller = __CALLER__

    expand = fn
      {:__aliases__, _, _} = ast -> Macro.expand(ast, caller)
      other -> other
    end

    oban_opts = [
      queue: Keyword.get(opts, :queue, :ash_hooks),
      max_attempts: Keyword.get(opts, :max_attempts, 20)
    ]

    job_timeout = Keyword.get(opts, :timeout, 35_000)
    attempt_timeout = Keyword.get(opts, :attempt_timeout, 25_000)
    finalization_allowance = Keyword.get(opts, :finalization_allowance, 5_000)

    if job_timeout <= attempt_timeout + finalization_allowance do
      raise ArgumentError,
            "AshHooks.Worker :timeout must exceed :attempt_timeout plus :finalization_allowance"
    end

    {resolver_m, resolver_f} = Keyword.fetch!(opts, :secret_resolver)

    http_opts =
      case Keyword.get(opts, :http_opts) do
        {:{}, _, [m, f, a]} when is_atom(f) and is_list(a) -> {expand.(m), f, a}
        other -> other
      end

    worker_module = caller.module
    dispatch_route = AshHooks.OutboundBinding.named_route(worker_module, :enqueue)

    snippet_redactor =
      case Keyword.get(opts, :snippet_redactor) do
        nil ->
          nil

        # the module half arrives as alias AST — expand against the caller
        # (the secret_resolver precedent)
        {m, f} when is_atom(f) ->
          validate_redactor(expand.(m), f)

        other ->
          raise ArgumentError,
                "AshHooks.Worker :snippet_redactor must be {module, function} " <>
                  "(a 1-arity fn is accepted in the delivery config) — got #{inspect(other)}"
      end

    delivery_config =
      [
        deliveries: expand.(Keyword.fetch!(opts, :deliveries)),
        endpoints: expand.(Keyword.fetch!(opts, :endpoints)),
        secret_resolver: {expand.(resolver_m), resolver_f},
        snippet_redactor: snippet_redactor,
        tenant_aware_secrets: Keyword.get(opts, :tenant_aware_secrets, false),
        http: maybe_expand(Keyword.get(opts, :http), expand),
        # the adapter-opts seam (timeout overrides, :cacerts private-CA
        # bundles). Compile-time LITERALS bake as-is; anything computed
        # must arrive as {m, f, a} and is applied per-perform (a macro-time
        # function call would otherwise bake as unevaluated AST)
        http_opts: http_opts,
        attempt_timeout: attempt_timeout,
        finalization_allowance: finalization_allowance,
        dispatch_route: dispatch_route,
        max_attempts: Keyword.get(opts, :delivery_max_attempts, 10),
        base_backoff_seconds: Keyword.get(opts, :base_backoff_seconds, 2),
        max_backoff_seconds: Keyword.get(opts, :max_backoff_seconds, 3600),
        retry_after_cap_seconds: Keyword.get(opts, :retry_after_cap_seconds, 86_400)
      ]
      |> Macro.escape()

    oban_instance = maybe_expand(Keyword.get(opts, :oban, Oban), expand)

    quote do
      unless Code.ensure_loaded?(Oban) do
        raise ArgumentError,
              "AshHooks.Worker requires Oban on the host — add {:oban, \"~> 2.20\"} " <>
                "to the app's deps (ADR-0004: the package itself stays Oban-free; " <>
                "this module compiles the Oban beam only where Oban exists)"
      end

      use Oban.Worker, unquote(oban_opts)

      # the job timeout (a stalled peer must not occupy a worker slot
      # forever — OSS Oban's default is :infinity)
      @impl Oban.Worker
      def timeout(_job), do: unquote(job_timeout)

      @ash_hooks_delivery_config unquote(delivery_config)
      @ash_hooks_oban unquote(oban_instance)

      @impl Oban.Worker
      def perform(%Oban.Job{args: args}) do
        AshHooks.Delivery.run(args, @ash_hooks_delivery_config)
      end

      # The enqueue seam (`enqueue: {__MODULE__, :enqueue}`) suppresses a
      # duplicate runnable job for the same delivery identity. Terminal jobs
      # do not block a later recovery enqueue. Multitenant deliveries carry
      # their row tenant in the args (read off the multitenancy attribute —
      # Ash itself set it from the dispatch tenant at create); single-tenant
      # rows serialize no tenant key at all.
      def enqueue(delivery, _event) do
        expected_route = unquote(dispatch_route)
        tenant = delivery_tenant(delivery)

        with {:ok, delivery} <- AshHooks.Worker.bind_route(delivery, expected_route, tenant) do
          args =
            %{
              delivery_pk: AshHooks.PrimaryKey.encode(delivery),
              delivery_resource: Atom.to_string(delivery.__struct__),
              endpoint_resource: Atom.to_string(@ash_hooks_delivery_config[:endpoints]),
              endpoint_id: to_string(delivery.endpoint_id),
              event_uuid: delivery.event_uuid,
              dispatch_source: delivery.dispatch_source,
              dispatch_route: delivery.dispatch_route,
              tenant: tenant
            }
            |> Enum.reject(fn {_key, value} -> is_nil(value) end)
            |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

          changeset =
            __MODULE__.new(args,
              unique: [
                fields: [:args],
                keys: [
                  :delivery_pk,
                  :delivery_resource,
                  :endpoint_resource,
                  :endpoint_id,
                  :event_uuid,
                  :dispatch_source,
                  :dispatch_route,
                  :tenant
                ],
                period: :infinity,
                states: [:available, :scheduled, :executing, :retryable]
              ]
            )

          insert_durably(changeset, args, 20)
        end
      end

      defp insert_durably(changeset, expected, retries_left) do
        case Oban.insert(@ash_hooks_oban, changeset) do
          {:ok, %Oban.Job{id: nil, conflict?: true}} when retries_left > 0 ->
            Process.sleep(5)
            insert_durably(changeset, expected, retries_left - 1)

          {:ok, %Oban.Job{} = job} ->
            durable_admission(job, expected)

          {:error, reason} ->
            {:error, reason}
        end
      end

      defp durable_admission(%Oban.Job{id: id, state: state, args: args}, expected)
           when not is_nil(id) and state in ["available", "scheduled", "executing", "retryable"] do
        if Map.take(args, Map.keys(expected)) == expected do
          :ok
        else
          {:error, :job_identity_mismatch}
        end
      end

      defp durable_admission(%Oban.Job{id: nil}, _expected), do: {:error, :job_not_persisted}
      defp durable_admission(_job, _expected), do: {:error, :job_not_runnable}

      # the tenant rides the args only when the ledger carries a
      # multitenancy attribute (undeclared → nil → no key)
      # the row holds the ATTRIBUTE value; the args carry the TENANT —
      # inverted through the resource's tenant_from_attribute so
      # Delivery.run's forward parse_attribute round-trips for
      # NON-identity parsers too (serializing the attribute value itself
      # would be double-parsed there)
      defp delivery_tenant(delivery) do
        resource = delivery.__struct__

        case ResourceInfo.multitenancy_attribute(resource) do
          nil ->
            nil

          attribute ->
            {m, f, a} = ResourceInfo.multitenancy_tenant_from_attribute(resource)
            apply(m, f, [Map.get(delivery, attribute) | a])
        end
      end
    end
  end
end
