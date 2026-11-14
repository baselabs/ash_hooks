defmodule AshHooks.Inbound.ResolvedSource do
  @moduledoc """
  One resolved inbound declaration, shared by the HTTP entry point and ingress.

  Scope contains cast and constrained ledger scope values. Keys contain the
  current custody key and an admitted, dated previous key. A pinned public
  verification key is separate from custody. Sources without a source resource
  use their declaration's existing secret callbacks during verification.
  """
  defstruct [
    :name,
    :provider_alias,
    :provider,
    :public_key,
    :record,
    scope: %{},
    paused?: false,
    keys: []
  ]

  @type t :: %__MODULE__{
          name: atom(),
          scope: map(),
          provider_alias: atom() | nil,
          provider: module(),
          paused?: boolean(),
          keys: [AshHooks.Custody.Key.t()],
          public_key: term(),
          record: struct() | nil
        }
end
