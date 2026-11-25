# Parse the source without loading Mix or evaluating the selected checkout.
[path] = System.argv()
contents = File.read!(path)

refuse = fn message ->
  IO.puts(:stderr, message)
  System.halt(1)
end

unless String.valid?(contents), do: refuse.("mix.exs must be valid UTF-8")

if String.starts_with?(contents, <<0xEF, 0xBB, 0xBF>>),
  do: refuse.("mix.exs must not start with a UTF-8 BOM")

source =
  case Code.string_to_quoted(contents, file: path) do
    {:ok, source} -> source
    {:error, _} -> refuse.("Could not parse mix.exs")
  end

{_, assignments} =
  Macro.prewalk(source, [], fn
    {:@, _, [{:version, _, [_ | _] = args}]} = node, assignments ->
      {node, [args | assignments]}

    {{:., _, [receiver, function]}, _, args} = node, assignments ->
      receiver =
        case receiver do
          {:__aliases__, _, parts} -> parts
          literal -> literal
        end

      case {receiver, function, args} do
        {kernel, :@, [{:version, _, [_ | _] = version_args}]}
        when kernel in [Kernel, [:Kernel], [:Elixir, :Kernel]] ->
          {node, [version_args | assignments]}

        {module, function, [_, :version | _]}
        when module in [Module, [:Module], [:Elixir, :Module]] and
               function in [:put_attribute, :register_attribute] ->
          refuse.("Module APIs must not set or register @version in mix.exs")

        _ ->
          {node, assignments}
      end

    node, assignments ->
      {node, assignments}
  end)

version =
  case assignments do
    [[version]] when is_binary(version) -> version
    _ -> refuse.("Expected exactly one string-literal @version assignment in mix.exs")
  end

case Version.parse(version) do
  {:ok, _} -> IO.puts(version)
  :error -> refuse.("Expected a semantic Mix project version")
end
