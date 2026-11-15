defmodule AshHooks.Errors.Invalid.KeyKindMismatch do
  @moduledoc """
  A custody key or pinned public key has a kind that cannot perform the requested operation.
  This is a final configuration fault. Telemetry reason: `:key_kind_mismatch`.
  """

  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "webhook key kind does not support the requested operation"
end
