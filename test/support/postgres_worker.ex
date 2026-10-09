# Compile the same worker used by the PostgreSQL suite so the type gate
# analyzes the consumer code injected by AshHooks.Worker.
if Code.ensure_loaded?(Oban) do
  defmodule AshHooks.OutboundPostgresReadinessTest.Worker do
    @moduledoc false
    use AshHooks.Worker,
      deliveries: AshHooks.OutboundPostgresReadinessTest.Delivery,
      endpoints: AshHooks.OutboundPostgresReadinessTest.Endpoint,
      secret_resolver: {AshHooks.OutboundPostgresReadinessTest.Runtime, :secret},
      oban: AshHooks.OutboundPostgresReadinessTest.Oban,
      queue: :outbound_readiness
  end
end
