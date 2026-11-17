[extensions | flags] = System.argv()

stale =
  for name <- String.split(extensions, ",") do
    extension = Module.concat([name])
    Code.ensure_compiled!(extension)

    # Render option tables as HTML so their explicit row anchors survive both
    # GitHub Markdown and ExDoc. Earmark escapes inline HTML in Markdown cells.
    text =
      extension
      |> Spark.CheatSheet.cheat_sheet()
      |> then(fn text ->
        Regex.replace(~r/^(#+) ([\w]+(?:\.[\w]+)+)$/m, text, fn heading, level, title ->
          anchor = String.replace(title, ".", "-")

          if level == "#" do
            heading <> "\n\n<a id=\"#{anchor}\"></a>"
          else
            "<h#{String.length(level)} id=\"#{anchor}\">#{title}</h#{String.length(level)}>"
          end
        end)
      end)
      |> then(fn text ->
        Regex.replace(~r/^\|[^\n]+\n\|[- :|]+\n(?:\|[^\n]+(?:\n|$))+/m, text, fn table ->
          if String.contains?(table, "{: #") do
            table
            |> String.replace(".spark-required}", ".spark-required} **required**")
            |> ExDoc.Markdown.to_ast(markdown_processor: ExDoc.Markdown.Earmark)
            |> ExDoc.DocAST.to_html()
            |> Kernel.<>("\n")
          else
            table
          end
        end)
      end)

    # Spark descriptions carry their fragment dispositions into both API and
    # generated reference docs. Spark's own declaration signatures need a host too.
    {nodes, _} = EarmarkParser.Parser.parse_markdown(text, %EarmarkParser.Options{})

    code_nodes = fn walk, nodes ->
      Enum.flat_map(nodes, fn
        %EarmarkParser.Block.Code{} = code -> [code]
        %{blocks: children} -> walk.(walk, children)
        _ -> []
      end)
    end

    lines = String.split(text, "\n")

    unmarked =
      for node <- code_nodes.(code_nodes, nodes),
          previous =
            lines
            |> Enum.take(node.lnb - 1)
            |> Enum.reverse()
            |> Enum.find(&(String.trim(&1) != "")),
          not String.contains?(previous || "", ["<!-- tested:", "<!-- not-run:"]),
          do: node.lnb

    text =
      lines
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {line, number} ->
        if number in unmarked do
          "<!-- not-run: This Spark DSL signature requires a named declaration in an enclosing host resource. -->\n" <>
            line
        else
          line
        end
      end)

    path = "documentation/dsls/DSL-#{name}.md"

    if "--check" in flags do
      unless File.read!(path) == text do
        IO.puts("BEGIN GENERATED #{path}\n" <> text <> "\nEND GENERATED #{path}")
        path
      end
    else
      File.write!(path, text)
    end
  end

if "--check" in flags and Enum.any?(stale) do
  Mix.raise("DSL references are stale; run mix spark.generate")
end
