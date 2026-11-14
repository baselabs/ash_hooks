defmodule AshHooks.Errors.Invalid.UnknownKey do
  @moduledoc """
  A custody key is absent or belongs to another tenant.
  A displaced reference is refreshed once from its owner. A reference still
  admitted by that owner is a final configuration fault. Telemetry reason: `:unknown_key`.
  """

  use Splode.Error, fields: [:ref], class: :invalid

  def message(_error), do: "unknown webhook key"
end
