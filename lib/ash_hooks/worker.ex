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
      The returned binary's prefix (`whsec_`/`whsk_`, or raw legacy
      material) selects its signature slot.
    * `:http` — the `AshHooks.Http` adapter (default `AshHooks.Http.Httpc`).
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

    delivery_config =
      [
        deliveries: expand.(Keyword.fetch!(opts, :deliveries)),
        endpoints: expand.(Keyword.fetch!(opts, :endpoints)),
        secret_resolver: {expand.(resolver_m), resolver_f},
        http: maybe_expand(Keyword.get(opts, :http), expand),
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
