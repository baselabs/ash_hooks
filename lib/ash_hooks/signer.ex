defmodule AshHooks.Signer do
  @moduledoc """
  Host-owned signing for a fully prepared outbound delivery.

  Declare the module with `endpoint.signer`. Resolve keys through the host's
  own custody or KMS under `context.tenant` (or `context.custody_tenant` when
  present). Native package keys belong only to their native protocol.

  Return nonempty ordered new header lines and 1 to 8 nonempty UTF-8 key
  references, each at most 255 bytes, or `:skip`, `{:error, :retry}` or
  `{:error, :terminal}`. Headers cannot collide with existing names or the
  reserved delivery headers. Callback contents and failures are never retained;
  only a fixed outcome class reaches the ledger or telemetry.
  """

  @type context :: %{
          delivery: struct(),
          endpoint: struct(),
          attempt: pos_integer(),
          event_id: String.t(),
          tenant: term(),
          custody_tenant: String.t() | nil
        }
  @callback sign(AshHooks.Http.Request.t(), context()) ::
              {:ok, [{String.t(), String.t()}], %{key_refs: [String.t()]}}
              | :skip
              | {:error, :retry | :terminal}
end
