defmodule AshHooks.Verifiers.ReplayWindowRequiresTimestamp do
  @moduledoc false
  # Fail-closed: a `replay_window_seconds` on an inbound declaration is only
  # meaningful when the provider's signature scheme carries a trustworthy
  # timestamp. A window over a timestamp-less scheme silently verifies
  # replays forever — the verifier rejects the combination at compile time
  # when the provider module is resolvable. Unresolvable providers are left
  # to the ingress's runtime fail-closed resolution.
  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  def verify(dsl_state) do
    resource = Verifier.get_persisted(dsl_state, :module)

    dsl_state
    |> Verifier.get_entities([:webhooks])
    |> Enum.filter(&(is_struct(&1, AshHooks.Inbound) and &1.replay_window_seconds))
    |> Enum.each(&check_timestamp(resource, &1))

    :ok
  end

  defp check_timestamp(resource, entity) do
    case resolve_provider(entity) do
      {:ok, provider} -> require_timestamp(resource, entity, provider)
      :error -> :ok
    end
  end

  defp require_timestamp(resource, entity, provider) do
    unless AshHooks.Provider.timestamp_header(provider) do
      raise Spark.Error.DslError,
        module: resource,
        path: [:webhooks, :inbound, entity.name],
        message:
          "replay_window_seconds requires a provider with a trustworthy timestamp — " <>
            "#{inspect(provider)} declares none (AshHooks.Provider.timestamp_header/1 is nil)"
    end
  end

  defp resolve_provider(entity) do
    candidate = entity.provider || name_module(entity.name)

    # ensure_compiled waits for in-project parallel compilation where
    # ensure_loaded? reports a sibling module as absent (cross-vendor finding)
    if is_atom(candidate) and Code.ensure_compiled(candidate) == {:module, candidate} and
         function_exported?(candidate, :verify_signature, 3) do
      {:ok, candidate}
    else
      :error
    end
  end

  defp name_module(name) do
    Module.concat(AshHooks.Provider, Macro.camelize(Atom.to_string(name)))
  end
end
