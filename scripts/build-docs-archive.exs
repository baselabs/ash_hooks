unless is_nil(Mix.Project.get()) do
  Mix.raise("Docs archives must be built outside a Mix project")
end

[directory, output] = System.argv()
directory = Path.expand(directory)

unless File.regular?(Path.join(directory, "index.html")) do
  Mix.raise("Documentation must contain a top-level index.html")
end

Hex.start()
Code.ensure_loaded!(:mix_hex_tarball)

# Hex omits dotfiles. Remove ExDoc's transient build manifests so the source
# tree contains exactly the files the publisher archives, without omitting docs.
for name <- [".build", ".build.epub", ".build.markdown"] do
  case File.rm(Path.join(directory, name)) do
    :ok -> :ok
    {:error, :enoent} -> :ok
    {:error, reason} -> Mix.raise("Cannot remove ExDoc manifest: #{reason}")
  end
end

files =
  directory
  |> Path.join("**")
  |> Path.wildcard()
  |> Enum.filter(&File.regular?/1)
  |> Enum.map(fn path ->
    name = Path.relative_to(path, directory)
    top_level = name |> Path.split() |> List.first()

    if match?({:ok, _}, Version.parse(top_level)) do
      Mix.raise("Top-level documentation filenames cannot be semantic versions")
    end

    {String.to_charlist(name), File.read!(path)}
  end)

{:ok, data} = :mix_hex_tarball.create_docs(files)
File.write!(output, data)
IO.puts("Docs archive: #{output}")
