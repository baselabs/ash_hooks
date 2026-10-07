defmodule AshHooks.Verifiers.OutboundDeliveryFields do
  @moduledoc false

  use Spark.Dsl.Verifier

  alias Spark.Dsl.Verifier

  @ownership_fields [
    dispatch_source: {Ash.Type.String, false, true, "v1:direct:unbound"},
    dispatch_route: {Ash.Type.String, false, true, "v1:route:unbound"},
    attempt_token: {Ash.Type.UUID, true, false, nil},
    send_lease_expires_at: {Ash.Type.UtcDatetimeUsec, true, false, nil},
    enqueue_token: {Ash.Type.UUID, true, false, nil},
    enqueue_lease_expires_at: {Ash.Type.UtcDatetimeUsec, true, false, nil},
    endpoint_snapshot: {Ash.Type.Map, true, false, nil}
  ]

  @impl Spark.Dsl.Verifier
  def verify(dsl_state) do
    attributes =
      dsl_state
      |> Verifier.get_entities([:attributes])
      |> Map.new(&{&1.name, &1})

    Enum.each(@ownership_fields, fn {name, expected} ->
      verify_field!(dsl_state, Map.fetch!(attributes, name), name, expected)
    end)

    :ok
  end

  defp verify_field!(dsl_state, attribute, name, {type, allow_nil?, writable?, default}) do
    problems =
      []
      |> mismatch(attribute, :type, type, &inspect/1)
      |> mismatch(attribute, :allow_nil?, allow_nil?, &inspect/1)
      |> mismatch(attribute, :writable?, writable?, &inspect/1)
      |> mismatch(attribute, :default, default, &inspect/1)
      |> maybe_check_route_capacity(attribute, name)

    if problems != [] do
      raise Spark.Error.DslError,
        module: Verifier.get_persisted(dsl_state, :module),
        path: [:attributes, name],
        message:
          "#{name} is an outbound ownership field and must keep the injected contract: " <>
            Enum.join(Enum.reverse(problems), ", ")
    end
  end

  defp mismatch(problems, attribute, property, expected, format) do
    actual = Map.get(attribute, property)

    if actual == expected do
      problems
    else
      ["#{property} must be #{format.(expected)}, got #{format.(actual)}" | problems]
    end
  end

  defp maybe_check_route_capacity(problems, attribute, name)
       when name in [:dispatch_source, :dispatch_route] do
    case attribute.constraints[:max_length] do
      nil -> problems
      max when is_integer(max) and max >= 1024 -> problems
      other -> ["max_length must be at least 1024, got #{inspect(other)}" | problems]
    end
  end

  defp maybe_check_route_capacity(problems, _attribute, _name), do: problems
end
