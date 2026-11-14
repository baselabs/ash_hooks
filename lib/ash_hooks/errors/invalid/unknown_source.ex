defmodule AshHooks.Errors.Invalid.UnknownSource do
  @moduledoc "An inbound source could not be resolved. Telemetry reason: `:unknown_source`."

  use Splode.Error, fields: [], class: :invalid

  def message(_error), do: "unknown webhook source"
end
