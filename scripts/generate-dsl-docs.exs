[extensions | flags] = System.argv()

for name <- String.split(extensions, ",") do
  extension = Module.concat([name])
  Code.ensure_compiled!(extension)

  text = Spark.CheatSheet.cheat_sheet(extension)

  path = "documentation/dsls/DSL-#{name}.md"

  if "--check" in flags do
    unless File.read!(path) == text, do: Mix.raise("#{path} is stale; run mix spark.generate")
  else
    File.write!(path, text)
  end
end
