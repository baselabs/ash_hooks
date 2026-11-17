[extensions | flags] = System.argv()

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

  path = "documentation/dsls/DSL-#{name}.md"

  if "--check" in flags do
    unless File.read!(path) == text, do: Mix.raise("#{path} is stale; run mix spark.generate")
  else
    File.write!(path, text)
  end
end
