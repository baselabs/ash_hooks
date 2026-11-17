defmodule AshHooks.Provider.DeliveryContext do
  @moduledoc """
  Durable context for provider callbacks, with and without a source resource.

  | Field | parse_event_type/2 and event_identity/2 | handle_event/3 |
  | --- | --- | --- |
  | tenant, source, scope, provider_alias | Set at ingest | Rebuilt from the stored receipt on every claim |
  | delivery_id, external_event_id | nil | Set from the stored receipt |
  | verified_facts | nil | Rebuilt from the stored receipt when recording is on |

  `provider_alias` is nil for declarations without `source_record`.
  A composite delivery key is a map; a single delivery key is its value.
  Request headers and a receipt timestamp are absent because recovery cannot
  reconstruct them. A handler needing host-owned receipt fields can read its
  ledger by `delivery_id` under `tenant`.
  """
  @derive {Inspect, except: [:verified_facts]}
  defstruct [
    :verified_facts,
    :tenant,
    :source,
    :provider_alias,
    :delivery_id,
    :external_event_id,
    scope: %{}
  ]

  @type t :: %__MODULE__{
          verified_facts: map() | nil,
          tenant: term(),
          source: atom(),
          scope: map(),
          provider_alias: atom() | nil,
          delivery_id: term(),
          external_event_id: binary() | nil
        }
end
