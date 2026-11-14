defmodule AshHooks.Worker do
  @moduledoc """
  Defines an Oban worker in the consuming application. Define the worker in
  your application when Oban is installed. The package also compiles and works
  without Oban; use `AshHooks.Delivery.run/2` for direct delivery.

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

    * `:deliveries`, `:endpoints` (required); the consumer's resource
      modules carrying the `AshHooks.OutboundDelivery` / `AshHooks.Endpoint`
      extensions.
    * `:attempts` (optional); the consumer's resource module carrying
      `AshHooks.OutboundAttempt`: when set, every delivery attempt records
      a durable history row (time, outcome, classified reason, HTTP
      status, latency, the signing key reference; per-endpoint-opt-in
      response capture) beside the delivery row. A history write failure
      never fails the send; it surfaces as
      `[:ash_hooks, :attempt, :record_failed]` telemetry.
    * `:secret_resolver` (required, `{m, f}`); resolves an endpoint's
      secret reference: `f(ref) :: {:ok, secret_binary} | {:error, term}`.
      The returned value signs the Standard Webhooks envelope
      (its `whsk_`/`whsec_` prefix only selects the key slot for
      rotation); legacy envelopes, when the signing mode uses them, are
      signed from the endpoint's `legacy_secret_ref` /
      `legacy_previous_secret_ref` references through this same resolver.
    * `:tenant_aware_secrets` (optional, default `false`); switches the
      resolver contract to 2-arity: `f(ref, tenant)`. The tenant is the
      run's args-threaded tenant (the delivery row's tenant, serialized at
      enqueue). Explicit, no arity magic: the default 1-arity contract is
      unchanged.
    * `:snippet_redactor` (`{m, f}`, optional); a consumer callback run
      on the raw captured body ahead of the package's snippet floor
      (domain-specific tokens need raw input). Only consulted on per-call
      `snippet_capture: true` diagnostic runs; a crash or invalid return
      degrades to the sanitized summary, never raw bytes. The capture
      flag is not a macro option. Enable diagnostic capture through a direct
      `AshHooks.Delivery.run/2` call.
    * `:destination_policy` (`{module, function}`, optional); the public
      send-time destination policy seam (`AshHooks.DestinationPolicy`):
      the callback receives the endpoint's URL and a context map
      (`%{endpoint_id:, tenant:}`) and returns `:allow` (skip the packaged
      SSRF gate; pair it with the adapter's validation override for
      destinations that check would refuse), `:deny` (terminal
      `destination_denied`), or `:default` (the packaged tri-state check
      runs unchanged). A crashing or out-of-vocabulary callback is
      contained as a retryable `destination_policy_failed`. A configured
      policy takes precedence over the boolean `:ssrf_check` seam.
    * `:transport`; the per-endpoint delivery transport resolver
      (`{module, function}` or a 2-arity fn of the endpoint record and
      tenant) returning an `AshHooks.Transport` module for one endpoint's
      deliveries; a developer's local forwarder behind a CLI "listen"
      command; or `nil` to keep the HTTP adapter. The same signing,
      attempts, and telemetry apply; a crashing resolver or non-module
      return falls back to the HTTP adapter.
    * `:http`; the `AshHooks.Http` adapter (default `AshHooks.Http.Bounded`).
    * `:retryable_statuses`; optional literal list of HTTP statuses/ranges;
      replaces the ordinary retry set. Omit it for 408/429/5xx. 2xx success,
      redirect refusal, and 410 disablement stay fixed.
    * `:delivery_headers`; optional `{module, function}` called with
      `(delivery, endpoint, tenant)` before each send. Return binary header
      pairs. Package signing, content-type, and framing headers cannot be
      overridden. Callback/validation failures retry without sending.
    * `:certificate_pin`; optional `{module, function}` called with
      `(endpoint, tenant)` each attempt. Return a pin supported by
      `AshHooks.Http.Bounded` or `nil` for off. Pin failure is non-retryable;
      a configured pin requires the bounded adapter and HTTPS. Computed
      host-wide pins can also be returned in `:http_opts`.
    * `:http_opts`; adapter options as a literal keyword list or a
      `{module, function, args}` callback resolved inside each job's monitored
      delivery deadline. Consumer-trusted config: a literal `timeout:` here
      must stay below `:attempt_timeout` (the macro refuses a larger one),
      and `validate_destination: false`; the test seam loopback listeners
      use; disables the adapter's resolve-and-pin defense, leaving only the
      driver's send-time destination check. The macro refuses to compile a
      literal bypass outside `:test`; never ship it to production.
    * `:oban`; the Oban instance name (default the unnamed instance).
    * `:queue` (default `:ash_hooks`), `:timeout` (35,000 ms), and
      `:max_attempts` (20); Oban Worker options. The job timeout must be
      greater than `:attempt_timeout + :finalization_allowance`, and Oban's
      `:max_attempts` must exceed `:delivery_max_attempts`: error-class
      results (attempt timeout, driver crash, endpoint read errors) consume
      Oban executions in step with row attempts while snooze-class results
      consume none, so only the row ceiling may decide dead-letter.
    * `:attempt_timeout` (25,000 ms) and `:finalization_allowance` (5,000 ms)
     ; the driver deadline and extra send-lease interval. The attempt budget
      includes endpoint lookup, secret resolution, signing, destination and
      DNS checks, HTTP, and result persistence. A literal `:http_opts`
      `timeout:` must stay below `:attempt_timeout` (the macro refuses a
      larger one; an `{m, f, a}` bundle resolves per-perform and cannot be
      compile-checked). Keep application clocks
      synchronized because lease comparisons use the application clock.
    * `:delivery_max_attempts` (default 10), `:base_backoff_seconds` (2),
      `:max_backoff_seconds` (3600), `:retry_after_cap_seconds` (86_400) ;
      the row-driven retry policy; every budget option must be a positive
      integer and `:max_backoff_seconds` at least `:base_backoff_seconds`.
      For direct `AshHooks.Delivery.run/2` calls,
      `:delivery_max_attempts` becomes `:max_attempts`; the other retry option
      names and defaults are unchanged. Omitted or `nil` retry options use
      these defaults. The `Retry-After` cap is
      the maximum delay a receiver can request on each attempt. A large
      `Retry-After` can keep a delivery and its job pending for up to the cap
      on each attempt. The default permits 24 hours per attempt.
      Lower the cap when failures need to reach the attempt
      limit sooner. The cap does not alter exponential backoff.
    * `:runtime_config` (`{module, function}`, optional); resolves the
      worker-timing options PER PERFORM: `f(job_args) :: keyword()` returns
      overrides for `:delivery_max_attempts`, `:base_backoff_seconds`,
      `:max_backoff_seconds`, `:retry_after_cap_seconds`, `:attempt_timeout`,
      and `:finalization_allowance`, merged over the compiled defaults (the
      compiled values are defaults; overrides may be lower or higher while
      staying within the compiled job timeout and attempt limits). The Oban job
      `:timeout` and `:max_attempts` stay compile-time (they are Oban Worker
      options baked into the generated module), so the compile-time misfit
      checks re-run at runtime against every resolved set: an override that
      overruns the baked job envelope, meets or exceeds the Oban attempt
      ceiling, is not a positive integer, inverts the backoff ladder,
      collides a literal `:http_opts` `timeout:` with a lowered
      `:attempt_timeout`, or names an unknown key fails
      `perform/1` with `{:error, {:invalid_runtime_config, reason}}` BEFORE
      any delivery work; the row is untouched, Oban re-drives the job, and
      a `[:ash_hooks, :worker, :invalid_runtime_config]` telemetry event
      carries the reason. A callback that raises or returns a non-keyword
      is contained the same way (`:callback_failed`). Raise the compiled
      `:timeout`/`:max_attempts` ceilings to the maximum you will ever
      resolve at runtime, then lower per run.

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
  tenant must round-trip Oban's JSON encoding; string tenants (uuids,
  slugs) are the supported shape; adopters with a custom `parse_attribute`
  pair it with `tenant_from_attribute` (the default inverse is identity).
  """

  require Ash.Query

  defp maybe_expand(nil, _expand), do: nil
  defp maybe_expand(value, expand), do: expand.(value)

  defp validate_redactor(m, f) when is_atom(m) and is_atom(f), do: {m, f}

  defp validate_redactor(m, f), do: raise(ArgumentError, redactor_error(m, f))

  defp validate_positive_budgets!(budgets) do
    Enum.each(budgets, fn {key, value} ->
      unless is_integer(value) and value > 0 do
        raise ArgumentError,
              "AshHooks.Worker #{inspect(key)} must be a positive integer, got #{inspect(value)}"
      end
    end)
  end

  # a literal driver timeout at or above the attempt budget walls off every
  # slow send at the runtime's kill line before the driver's own deadline
  # fires — an {m, f, a} bundle is resolved per-perform and cannot be
  # compile-checked
  defp validate_literal_driver_timeout!(literal, attempt_timeout) do
    case Keyword.get(literal, :timeout) do
      driver_timeout when is_integer(driver_timeout) and driver_timeout >= attempt_timeout ->
        raise ArgumentError,
              "AshHooks.Worker :http_opts timeout (#{driver_timeout}ms) must stay below " <>
                ":attempt_timeout (#{attempt_timeout}ms)"

      _absent_or_below ->
        :ok
    end
  end

  # the destination-validation bypass is the TEST seam for loopback
  # listeners; with it on, the driver's send-time check is the only
  # remaining layer. Refuse to bake it outside :test — a dev/prod worker
  # must not silently lose the adapter's resolve-and-pin. An {m, f, a}
  # bundle resolves per-perform and cannot be compile-checked
  defp validate_literal_destination_bypass!(literal) do
    if Mix.env() != :test and literal[:validate_destination] == false do
      raise ArgumentError,
            "AshHooks.Worker :http_opts validate_destination: false is the test seam for " <>
              "loopback listeners — the driver's send-time check would be the only remaining " <>
              "layer. Refusing to compile it outside :test"
    end
  end

  defp redactor_error(m, f) do
    "AshHooks.Worker :snippet_redactor must be {module, function} " <>
      "(a 1-arity fn is accepted in the delivery config) — got {#{inspect(m)}, #{inspect(f)}}"
  end

  defp runtime_config_error(other) do
    "AshHooks.Worker :runtime_config must be {module, function} " <>
      "(f receives the job args and returns a keyword of timing overrides) — " <>
      "got #{inspect(other)}"
  end

  defp destination_policy_error(other) do
    "AshHooks.Worker :destination_policy must be {module, function} " <>
      "(f receives the URL and a context map; see AshHooks.DestinationPolicy) — " <>
      "got #{inspect(other)}"
  end

  # ──────────────── the per-perform runtime-config seam ────────────────

  @doc """
  Resolves a worker's delivery config for one perform: when the worker
  declared `:runtime_config: {module, function}`, the callback runs with
  the job's args map (string keys, tenant included when the row carries
  one) and its overrides are merged over the compiled defaults; after
  the compiled-budget misfit checks re-run as runtime validation.

  Returns `{:ok, config}` (the driver-ready keyword list) or
  `{:error, {:invalid_runtime_config, reason}}`, where `reason` is
  `:callback_failed` (a crash or a non-keyword return; contained, never
  raised through), `{:unknown_key, key}`, `:not_positive_integer`,
  `:backoff_inversion`, `:envelope_exceeded` (the resolved attempt
  deadline overruns the baked Oban job timeout, or a literal
  `:http_opts` `timeout:` collides with a lowered `:attempt_timeout`),
  or `:oban_ceiling_exceeded` (the resolved delivery ceiling reaches the
  baked Oban job ceiling; only the row ceiling may decide dead-letter).
  A rejection emits `[:ash_hooks, :worker, :invalid_runtime_config]` and
  leaves the delivery row untouched.
  """
  @spec resolve_config(keyword(), map()) ::
          {:ok, keyword()} | {:error, {:invalid_runtime_config, term()}}
  def resolve_config(config, args) do
    case config[:runtime_config] do
      nil ->
        {:ok, config}

      {module, function} = seam when is_atom(module) and is_atom(function) ->
        resolve_runtime_seam(seam, config, args)

      _invalid ->
        reject_runtime_config({:error, :callback_failed})
    end
  end

  defp resolve_runtime_seam(seam, config, args) do
    with {:ok, overrides} <- runtime_overrides(seam, args),
         :ok <- check_unknown_keys(overrides) do
      merged = merge_runtime_overrides(config, overrides)
      resolve_merged_config(merged)
    else
      {:error, reason} -> reject_runtime_config({:error, reason})
    end
  end

  defp resolve_merged_config(merged) do
    case validate_runtime_budgets(merged) do
      :ok -> {:ok, merged}
      {:error, _reason} = error -> reject_runtime_config(error)
    end
  end

  # the callback runs OUTSIDE the driver's monitor (it must not consume the
  # attempt budget); a raise/exit/throw is contained as an invalid config —
  # the row is untouched and Oban re-drives the trigger
  defp runtime_overrides(seam, args) do
    overrides = apply(elem(seam, 0), elem(seam, 1), [args])

    if Keyword.keyword?(overrides) do
      {:ok, overrides}
    else
      {:error, :callback_failed}
    end
  rescue
    _reason -> {:error, :callback_failed}
  catch
    :exit, _reason -> {:error, :callback_failed}
    :throw, _value -> {:error, :callback_failed}
  end

  # the overridable set, in the WORKER'S option vocabulary; the delivery
  # ceiling maps onto the driver's :max_attempts key
  @runtime_budget_keys ~w(delivery_max_attempts base_backoff_seconds max_backoff_seconds
     retry_after_cap_seconds attempt_timeout finalization_allowance)a

  defp merge_runtime_overrides(config, overrides) do
    Enum.reduce(overrides, config, fn
      {:delivery_max_attempts, value}, config ->
        Keyword.put(config, :max_attempts, value)

      {key, value}, config ->
        Keyword.put(config, key, value)
    end)
  end

  # The compiled tripwires re-run at runtime over the EFFECTIVE values:
  # every overridable key is now runtime data, and a silent misfit here
  # has the same failure class the compile gate closes (stalled rows, a
  # budget wall ahead of the driver deadline, an Oban ceiling deciding
  # dead-letter). The Oban job timeout and ceiling stay the compiled
  # envelope the overrides must fit inside.
  defp validate_runtime_budgets(config) do
    with :ok <- check_runtime_positive(config),
         :ok <- check_runtime_backoff(config),
         :ok <- check_runtime_envelope(config) do
      check_runtime_oban_ceiling(config)
    end
  end

  defp check_unknown_keys(overrides) do
    case Enum.find(overrides, fn {key, _} -> key not in @runtime_budget_keys end) do
      nil -> :ok
      {key, _} -> {:error, {:unknown_key, key}}
    end
  end

  defp check_runtime_positive(config) do
    budgets = [
      attempt_timeout: config[:attempt_timeout],
      finalization_allowance: config[:finalization_allowance],
      max_attempts: config[:max_attempts],
      base_backoff_seconds: config[:base_backoff_seconds],
      max_backoff_seconds: config[:max_backoff_seconds],
      retry_after_cap_seconds: config[:retry_after_cap_seconds]
    ]

    case Enum.find(budgets, fn {_key, value} ->
           not (is_integer(value) and value > 0)
         end) do
      nil -> :ok
      {_key, _value} -> {:error, :not_positive_integer}
    end
  end

  defp check_runtime_backoff(config) do
    if config[:max_backoff_seconds] >= config[:base_backoff_seconds] do
      :ok
    else
      {:error, :backoff_inversion}
    end
  end

  defp check_runtime_envelope(config) do
    attempt_timeout = config[:attempt_timeout]
    allowance = config[:finalization_allowance]

    cond do
      attempt_timeout + allowance >= config[:job_timeout] ->
        {:error, :envelope_exceeded}

      literal_http_timeout(config) >= attempt_timeout ->
        {:error, :envelope_exceeded}

      true ->
        :ok
    end
  end

  # the compile-time literal check re-runs against the EFFECTIVE attempt
  # budget: a runtime override may lower :attempt_timeout beneath a baked
  # literal driver timeout, walling slow sends off at the runtime's kill
  # line. An {m, f, a} bundle resolves later and stays unchecked (the
  # compiled posture's documented caveat).
  defp literal_http_timeout(config) do
    case config[:http_opts] do
      literal when is_list(literal) -> Keyword.get(literal, :timeout, 0)
      _mfa_or_nil -> 0
    end
  end

  defp check_runtime_oban_ceiling(config) do
    if config[:oban_max_attempts] > config[:max_attempts] do
      :ok
    else
      {:error, :oban_ceiling_exceeded}
    end
  end

  defp reject_runtime_config({:error, reason}) do
    :telemetry.execute(
      [:ash_hooks, :worker, :invalid_runtime_config],
      %{},
      %{reason: classify_rejection(reason)}
    )

    {:error, {:invalid_runtime_config, reason}}
  end

  # the event's reason is the fixed validation vocabulary; a contained
  # callback failure's arbitrary term never rides the metadata
  defp classify_rejection({:unknown_key, _key}), do: "unknown_key"
  defp classify_rejection(reason) when is_atom(reason), do: Atom.to_string(reason)

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
    oban_max_attempts = Keyword.get(opts, :max_attempts, 20)
    delivery_max_attempts = Keyword.get(opts, :delivery_max_attempts, 10)
    base_backoff = Keyword.get(opts, :base_backoff_seconds, 2)
    max_backoff = Keyword.get(opts, :max_backoff_seconds, 3600)
    retry_after_cap = Keyword.get(opts, :retry_after_cap_seconds, 86_400)

    # compiled budget tripwires: these are related budgets, and a silent
    # misfit either stalls rows or walls off every slow send — refuse at
    # compile time, where every value but an MFA-resolved http_opts is
    # in hand
    validate_positive_budgets!(
      attempt_timeout: attempt_timeout,
      finalization_allowance: finalization_allowance,
      delivery_max_attempts: delivery_max_attempts,
      timeout: job_timeout,
      max_backoff_seconds: max_backoff,
      base_backoff_seconds: base_backoff,
      retry_after_cap_seconds: retry_after_cap
    )

    if job_timeout <= attempt_timeout + finalization_allowance do
      raise ArgumentError,
            "AshHooks.Worker :timeout must exceed :attempt_timeout plus :finalization_allowance"
    end

    if max_backoff < base_backoff do
      raise ArgumentError,
            "AshHooks.Worker :max_backoff_seconds must be at least :base_backoff_seconds"
    end

    # error-class results (attempt timeout, driver crash, endpoint read
    # errors) consume Oban executions in step with row attempts while
    # snooze-class results consume none, so Oban's ceiling must sit above
    # the row ceiling — only the row ceiling may decide dead-letter
    if oban_max_attempts <= delivery_max_attempts do
      raise ArgumentError,
            "AshHooks.Worker :max_attempts (the Oban job ceiling) must exceed " <>
              ":delivery_max_attempts (the row-owned retry ceiling)"
    end

    {resolver_m, resolver_f} = Keyword.fetch!(opts, :secret_resolver)

    destination_policy =
      case Keyword.get(opts, :destination_policy) do
        nil ->
          nil

        # the module half arrives as alias AST — expand against the caller
        # (the secret_resolver precedent)
        {m, f} = pair ->
          case {expand.(m), f} do
            {module, function} when is_atom(module) and is_atom(function) ->
              {module, function}

            _malformed ->
              raise ArgumentError, destination_policy_error(pair)
          end

        other ->
          raise ArgumentError, destination_policy_error(other)
      end

    runtime_config =
      case Keyword.get(opts, :runtime_config) do
        nil ->
          nil

        # the module half arrives as alias AST — expand against the caller
        # (the secret_resolver precedent); anything that does not resolve
        # to a module atom is the malformed shape, fail-closed at compile
        {m, f} = pair ->
          case {expand.(m), f} do
            {module, function} when is_atom(module) and is_atom(function) ->
              {module, function}

            _malformed ->
              raise ArgumentError, runtime_config_error(pair)
          end

        other ->
          raise ArgumentError, runtime_config_error(other)
      end

    http_opts =
      case Keyword.get(opts, :http_opts) do
        {:{}, _, [m, f, a]} when is_atom(f) and is_list(a) -> {expand.(m), f, a}
        other -> other
      end

    case http_opts do
      literal when is_list(literal) ->
        validate_literal_driver_timeout!(literal, attempt_timeout)
        validate_literal_destination_bypass!(literal)

      _mfa_or_nil ->
        :ok
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
        attempts: maybe_expand(Keyword.get(opts, :attempts), expand),
        transport:
          case Keyword.get(opts, :transport) do
            # the module half arrives as alias AST — expand, then check both
            {m, f} = pair ->
              case {expand.(m), f} do
                {module, function} when is_atom(module) and is_atom(function) ->
                  {module, function}

                _malformed ->
                  raise ArgumentError,
                        "AshHooks.Worker :transport must be {module, function} or a 2-arity fn — got #{inspect(pair)}"
              end

            other ->
              other
          end,
        secret_resolver: {expand.(resolver_m), resolver_f},
        retryable_statuses: retryable_statuses!(Keyword.get(opts, :retryable_statuses)),
        delivery_headers:
          case Keyword.get(opts, :delivery_headers) do
            {m, f} when is_atom(f) -> {expand.(m), f}
            other -> other
          end,
        certificate_pin:
          case Keyword.get(opts, :certificate_pin) do
            {m, f} when is_atom(f) -> {expand.(m), f}
            other -> other
          end,
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
        # the runtime-config seam (per-perform overrides) and the baked
        # envelope those overrides must fit inside — the compile-time misfit
        # checks re-run against every resolved set
        runtime_config: runtime_config,
        destination_policy: destination_policy,
        job_timeout: job_timeout,
        oban_max_attempts: oban_max_attempts,
        max_attempts: delivery_max_attempts,
        base_backoff_seconds: base_backoff,
        max_backoff_seconds: max_backoff,
        retry_after_cap_seconds: retry_after_cap
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
        case AshHooks.Worker.resolve_config(@ash_hooks_delivery_config, args) do
          {:ok, config} -> AshHooks.Delivery.run(args, config)
          {:error, reason} -> {:error, reason}
        end
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
          {:ok, %Oban.Job{} = job} ->
            if job.conflict? == true and not job_persisted?(job) and retries_left > 0 do
              Process.sleep(5)
              insert_durably(changeset, expected, retries_left - 1)
            else
              durable_admission(job, expected)
            end

          {:error, reason} ->
            {:error, reason}
        end
      end

      # Oban.Job.t() omits the unsaved uniqueness-conflict case (id: nil).
      # Read the map in a helper so consumer type checks retain that runtime case.
      defp job_persisted?(job), do: not is_nil(Map.get(job, :id))

      defp durable_admission(%Oban.Job{state: state, args: args} = job, expected) do
        cond do
          not job_persisted?(job) ->
            {:error, :job_not_persisted}

          state in ["available", "scheduled", "executing", "retryable"] ->
            if Map.take(args, Map.keys(expected)) == expected do
              :ok
            else
              {:error, :job_identity_mismatch}
            end

          true ->
            {:error, :job_not_runnable}
        end
      end

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

  defp retryable_statuses!(statuses) do
    resolved =
      if is_list(statuses) do
        Enum.map(statuses, fn
          {:.., _, [first, last]} when is_integer(first) and is_integer(last) ->
            Range.new(first, last)

          value ->
            value
        end)
      else
        statuses
      end

    case AshHooks.Delivery.validate_retryable_statuses(resolved) do
      :ok ->
        resolved

      {:error, _} ->
        raise ArgumentError,
              "AshHooks.Worker :retryable_statuses must be a literal list of HTTP status integers or ranges"
    end
  end
end
