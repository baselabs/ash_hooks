defmodule AshHooks.Worker do
  @moduledoc """
  The host-injected Oban worker (ADR-0004): the consuming app defines ONE
  module, and the Oban beam compiles only where Oban exists — this macro
  expands `use Oban.Worker` inside the HOST's compilation, so the package
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
  `AshHooks.dispatch/4` — the generated `enqueue/2` IS that seam.

  Options:

    * `:deliveries`, `:endpoints` (required) — the consumer's resource
      modules carrying the `AshHooks.OutboundDelivery` / `AshHooks.Endpoint`
      extensions.
    * `:secret_resolver` (required, `{m, f}`) — resolves an endpoint's
      secret REFERENCE: `f(ref) :: {:ok, secret_binary} | {:error, term}`.
      The returned value ALWAYS signs the Standard Webhooks envelope
      (its `whsk_`/`whsec_` prefix only selects the key slot for
      rotation); legacy envelopes, when the signing mode uses them, are
      signed from the endpoint's `legacy_secret_ref` /
      `legacy_previous_secret_ref` references through this same resolver.
    * `:snippet_redactor` (`{m, f}`, optional) — a consumer callback run
      on the RAW captured body ahead of the package's snippet floor
      (domain-specific tokens need raw input). Only consulted on per-call
      `snippet_capture: true` diagnostic runs; a crash or invalid return
      degrades to the sanitized summary, never raw bytes. The capture
      flag itself is deliberately NOT a macro option (ADR-0005's snippet
      amendment: compile-time knobs are broad and quiet) — pass it in the
      `AshHooks.Delivery.run/2` config for a one-row diagnostic re-drive.
    * `:http` — the `AshHooks.Http` adapter (default `AshHooks.Http.Bounded`).
    * `:oban` — the Oban instance name (default the unnamed instance).
    * `:queue`, `:timeout`, `:max_attempts` — Oban Worker options (the
      job's timeout defaults to 30s; its max_attempts is advisory only —
      snoozes extend it, the ROW's ceiling governs dead-letter).
    * `:delivery_max_attempts` (default 10), `:base_backoff_seconds` (2),
      `:max_backoff_seconds` (3600), `:retry_after_cap_seconds` (86_400) —
      the row-driven retry policy.

  Uniqueness (verified against deps/oban 2.23.1, ADR-0007):
  `fields: [:args], keys: [:endpoint_id, :event_uuid], period: :infinity,
  states: :all` — the defaults (60s / :successful) would re-admit a
  duplicate trigger after success or window expiry; both are overridden.
  A uniqueness conflict is `{:ok, %Oban.Job{conflict?: true}}` — the
  generated `enqueue/2` maps it to `:ok` (a conflict IS dedup success).
  """

  defp maybe_expand(nil, _expand), do: nil
  defp maybe_expand(value, expand), do: expand.(value)

  defp validate_redactor(m, f) when is_atom(m) and is_atom(f), do: {m, f}

  defp validate_redactor(m, f),
    do:
      raise(ArgumentError,
        message:
          "AshHooks.Worker :snippet_redactor must be {module, function} " <>
            "(a 1-arity fn is accepted in the delivery config) — got {#{inspect(m)}, #{inspect(f)}}"
      )

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

    job_timeout = Keyword.get(opts, :timeout, 30_000)

    {resolver_m, resolver_f} = Keyword.fetch!(opts, :secret_resolver)

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
        http: maybe_expand(Keyword.get(opts, :http), expand),
        # the adapter-opts seam (timeout overrides, :cacerts private-CA
        # bundles). Compile-time LITERALS bake as-is; anything computed
        # must arrive as {m, f, a} and is applied per-perform (a macro-time
        # function call would otherwise bake as unevaluated AST)
        http_opts: Keyword.get(opts, :http_opts),
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
        AshHooks.Delivery.run(args, resolve_http_opts(@ash_hooks_delivery_config))
      end

      # an {m, f, a} http_opts resolves at run time; literal lists pass as-is
      defp resolve_http_opts(config) do
        case config[:http_opts] do
          {m, f, a} when is_atom(m) and is_atom(f) and is_list(a) ->
            Keyword.put(config, :http_opts, apply(m, f, a))

          _literal_or_nil ->
            config
        end
      end

      # The #6 enqueue seam (`enqueue: {__MODULE__, :enqueue}`): inserts
      # the trigger with effect-once uniqueness; a uniqueness conflict is
      # dedup success, not an error.
      def enqueue(delivery, _event) do
        args = %{
          "endpoint_id" => to_string(delivery.endpoint_id),
          "event_uuid" => delivery.event_uuid
        }

        changeset =
          __MODULE__.new(args,
            unique: [
              fields: [:args],
              keys: [:endpoint_id, :event_uuid],
              period: :infinity,
              states: :all
            ]
          )

        case Oban.insert(@ash_hooks_oban, changeset) do
          {:ok, %Oban.Job{}} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end
  end
end
