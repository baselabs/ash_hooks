# Run from this checkout with the real PostgreSQL and public Httpbun gates enabled:
# ASH_HOOKS_POSTGRES=1 ASH_HOOKS_HTTPBUN=1 elixir scripts/check-ash-floor.exs
# PostgreSQL connection environment is the same as test/test_helper.exs.
Mix.start()
Mix.env(:test)

for flag <- ["ASH_HOOKS_POSTGRES", "ASH_HOOKS_HTTPBUN"] do
  unless System.get_env(flag) == "1", do: raise("#{flag}=1 is required for real qualification")
end

for override <- ["MIX_DEPS_PATH", "MIX_BUILD_PATH", "MIX_BUILD_ROOT", "ASH_HOOKS_NO_OPTIONAL"] do
  unless System.get_env(override) in [nil, ""],
    do: raise("unset #{override} so the qualification owns only its declared paths")
end

root = Path.expand("..", __DIR__)
qualification = Path.join(root, "_build/ash-floor")

fingerprint = fn ->
  for category <- ["mix.lock", "deps", "_build"], into: %{} do
    paths =
      case category do
        "mix.lock" -> [Path.join(root, category)]
        directory -> Path.wildcard(Path.join(root, directory <> "/**/*"), match_dot: true)
      end
      |> Enum.filter(&File.regular?/1)
      |> Enum.reject(&String.starts_with?(&1, qualification <> "/"))
      |> Enum.sort()

    known_positive =
      case category do
        "mix.lock" -> "mix.lock"
        "deps" -> "deps/ash/mix.exs"
        "_build" -> "_build/test/lib/ash/ebin/ash.app"
      end

    unless Path.join(root, known_positive) in paths,
      do: raise("identity instrument cannot see known-positive #{known_positive}")

    digest =
      Enum.reduce(paths, :crypto.hash_init(:sha256), fn path, context ->
        name = Path.relative_to(path, root)
        bytes = File.read!(path)
        :crypto.hash_update(context, [name, <<0>>, :crypto.hash(:sha256, bytes)])
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {category, %{files: length(paths), sha256: digest}}
  end
end

before = fingerprint.()
IO.puts("ROOT IDENTITY BEFORE: #{inspect(before)}")

source_paths =
  [
    "mix.exs",
    ".tool-versions",
    "test/test_helper.exs",
    "test/consumer/mix.exs",
    "test/consumer/verify.exs",
    "test/ash_hooks/tenant_worker_postgres_test.exs",
    "scripts/check-ash-floor.exs"
  ] ++ Path.wildcard(Path.join(root, "lib/**/*.ex"))

for path <- source_paths do
  absolute = Path.expand(path, root)
  hash = :crypto.hash(:sha256, File.read!(absolute)) |> Base.encode16(case: :lower)
  IO.puts("SOURCE SHA256 #{Path.relative_to(absolute, root)} #{hash}")
end

dependencies =
  Mix.Project.in_project(:ash_hooks, root, [], fn project -> project.project()[:deps] end)

unless List.keymember?(dependencies, :ash, 0), do: raise("root Ash dependency not found")
dependencies = List.keyreplace(dependencies, :ash, 0, {:ash, "== 3.34.3"})
File.mkdir_p!(qualification)
floor_lock = Path.join(qualification, "mix.lock")
File.cp!(Path.join(root, "mix.lock"), floor_lock)

post_config = [
  deps: dependencies,
  lockfile: floor_lock,
  deps_path: Path.join(qualification, "deps"),
  build_path: Path.join(qualification, "build")
]

try do
  Mix.Project.in_project(:ash_hooks, root, post_config, fn _project ->
    unless Mix.Project.config()[:lockfile] == floor_lock,
      do: raise("qualification lockfile override did not apply")

    IO.puts(
      "FLOOR PATHS: #{inspect(Mix.Project.config() |> Keyword.take([:lockfile, :deps_path, :build_path]))}"
    )

    Mix.Task.run("loadconfig")
    Mix.Task.run("deps.unlock", ["ash"])
    Mix.Task.run("deps.get")
    Mix.Task.run("compile", ["--warnings-as-errors"])
    Mix.Task.run("app.start")

    actual = to_string(Application.spec(:ash, :vsn))
    unless actual == "3.34.3", do: raise("expected loaded Ash 3.34.3, found #{actual}")
    IO.puts("LOADED ASH: #{actual}; #{:code.which(Ash.Resource.Info)}")

    Mix.Task.run("test", [
      "test/ash_hooks/tenant_worker_postgres_test.exs",
      "--trace",
      "--seed",
      "0",
      "--raise"
    ])

    IO.puts("FLOOR WORKER QUALIFICATION: exact Ash 3.34.3 focused case returned without failure")
  end)
after
  after_identity = fingerprint.()
  unless before == after_identity, do: raise("root lock/dependency/build identity changed")
  IO.puts("ROOT IDENTITY UNCHANGED: #{inspect(after_identity)}")
end
