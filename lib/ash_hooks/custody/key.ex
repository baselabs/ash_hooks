defmodule AshHooks.Custody.Key do
  @moduledoc """
  An opaque custody key, identified by custodian, reference, canonical tenant,
  and the kind fixed when it was stored. Contains no secret material.
  Sender public verification material uses `AshHooks.Custody.PublicKey`.
  """

  @enforce_keys [:custodian, :ref, :tenant, :kind]
  defstruct [:custodian, :ref, :tenant, :kind]

  @type t :: %__MODULE__{
          custodian: module(),
          ref: AshHooks.Custody.ref(),
          tenant: AshHooks.Custody.tenant(),
          kind: AshHooks.Custody.kind()
        }
end
