# Parse the source without loading Mix or evaluating the selected checkout.
[path] = System.argv()

case Code.string_to_quoted(File.read!(path), file: path) do
  {:ok, source} ->
    {_, assignments} =
      Macro.prewalk(source, [], fn
        {:@, _, [{:version, _, [_ | _] = args}]} = node, assignments ->
          {node, [args | assignments]}

        node, assignments ->
          {node, assignments}
      end)

    case assignments do
      [[version]] when is_binary(version) ->
        case Version.parse(version) do
          {:ok, _} ->
            IO.puts(version)

          :error ->
            IO.puts(:stderr, "Expected a semantic Mix project version")
            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Expected exactly one string-literal @version assignment in mix.exs")
        System.halt(1)
    end

  {:error, _} ->
    IO.puts(:stderr, "Could not parse mix.exs")
    System.halt(1)
end
