# Spark owns the content. Only its generated argument signatures need a
# not-run mark: their variable names describe syntax, not application code.
[extensions | flags] = System.argv()

for name <- String.split(extensions, ",") do
  extension = Module.concat([name])
  Code.ensure_compiled!(extension)

  signature = ~r/^(\#{3,} ([^\n]+))\n(```elixir\n[^\n]+\n```)/m

  text =
    Regex.replace(signature, Spark.CheatSheet.cheat_sheet(extension), fn _, heading, path, code ->
      marker = path |> String.replace(".", "-") |> String.replace("_", "-")

      "#{heading}\n<!-- tested: dsl-signature-#{marker}; not-run: Spark argument signature; names describe DSL syntax and require a host resource. -->\n#{code}"
    end)

  path = "documentation/dsls/DSL-#{name}.md"

  if "--check" in flags do
    unless File.read!(path) == text, do: Mix.raise("#{path} is stale; run mix spark.generate")
  else
    File.write!(path, text)
  end
end
