defmodule AshHooks.Errors.Invalid.UnknownKey do
  @moduledoc """
  A custody key is absent or belongs to another tenant.
  This is a final configuration fault. Telemetry reason: `:unknown_key`.
  """

  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "unknown webhook key"
end
