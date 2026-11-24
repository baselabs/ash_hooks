# Run from this checkout with the real PostgreSQL and public Httpbun gates enabled:
# ASH_HOOKS_POSTGRES=1 ASH_HOOKS_HTTPBUN=1 elixir scripts/check-ash-floor.exs
# PostgreSQL connection environment is the same as test/test_helper.exs.
#
# After a floor or requirement change, refresh the committed floor graph
# (resolution only, nothing compiles): elixir scripts/check-ash-floor.exs --update-lock
Mix.start()
Mix.env(:test)

update_lock? =
  case System.argv() do
    [] -> false
    ["--update-lock"] -> true
    _ -> raise("usage: check-ash-floor.exs [--update-lock]")
  end

for flag <- ["ASH_HOOKS_POSTGRES", "ASH_HOOKS_HTTPBUN"], not update_lock? do
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

dependencies =
  Mix.Project.in_project(:ash_hooks, root, [], fn project -> project.project()[:deps] end)

for dependency <- [:ash, :spark] do
  unless List.keymember?(dependencies, dependency, 0),
    do: raise("root #{dependency} dependency not found")
end

dependencies =
  dependencies
  |> List.keyreplace(:ash, 0, {:ash, "== 3.38.1"})
  |> List.keyreplace(:spark, 0, {:spark, "== 2.7.6"})

committed_lock = Path.join(root, "test/floor/mix.lock")

if update_lock? do
  File.rm_rf!(qualification)

  try do
    Mix.Project.in_project(
      :ash_hooks,
      root,
      [
        deps: dependencies,
        lockfile: committed_lock,
        deps_path: Path.join(qualification, "deps"),
        build_path: Path.join(qualification, "build")
      ],
      fn _project -> Mix.Task.run("deps.get") end
    )

    IO.puts("FLOOR LOCK UPDATED: #{Path.relative_to(committed_lock, root)}")
  after
    File.rm_rf!(qualification)
  end

  System.halt(0)
end

before = fingerprint.()
IO.puts("ROOT IDENTITY BEFORE: #{inspect(before)}")

source_paths =
  [
    "mix.exs",
    ".tool-versions",
    "test/floor/mix.lock",
    "scripts/check-ash-floor.exs"
  ] ++
    Path.wildcard(Path.join(root, "lib/**/*.ex")) ++
    Enum.reject(
      Path.wildcard(Path.join(root, "test/**/*.ex")) ++
        Path.wildcard(Path.join(root, "test/**/*.exs")),
      fn path ->
        Enum.any?(["test/consumer/deps/", "test/consumer/_build/"], fn directory ->
          String.starts_with?(Path.relative_to(path, root), directory)
        end)
      end
    )

for path <- source_paths do
  absolute = Path.expand(path, root)
  hash = :crypto.hash(:sha256, File.read!(absolute)) |> Base.encode16(case: :lower)
  IO.puts("SOURCE SHA256 #{Path.relative_to(absolute, root)} #{hash}")
end

File.rm_rf!(qualification)
File.mkdir_p!(qualification)
floor_lock = Path.join(qualification, "mix.lock")
# The committed floor graph, copied so the checkout's lock is never written.
File.cp!(committed_lock, floor_lock)

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
    # The committed floor graph, not the development lock, so transitive SQL
    # requirements cannot retain a newer Ash. Both direct floors are exact, and
    # --check-locked refuses a lock that no longer satisfies them.
    Mix.Task.run("deps.get", ["--check-locked"])
    Mix.Task.run("compile", ["--warnings-as-errors"])
    Mix.Task.run("app.start")

    actual = to_string(Application.spec(:ash, :vsn))
    unless actual == "3.38.1", do: raise("expected loaded Ash 3.38.1, found #{actual}")
    IO.puts("LOADED ASH: #{actual}; #{:code.which(Ash.Resource.Info)}")
    spark = to_string(Application.spec(:spark, :vsn))
    unless spark == "2.7.6", do: raise("expected loaded Spark 2.7.6, found #{spark}")
    IO.puts("LOADED SPARK: #{spark}; #{:code.which(Spark.Dsl.Extension)}")

    Mix.Task.run("test", ["--seed", "0", "--raise"])

    IO.puts(
      "FLOOR SUITE QUALIFICATION: exact Ash 3.38.1 and Spark 2.7.6 full suite returned without failure"
    )
  end)
after
  File.rm_rf!(qualification)
  after_identity = fingerprint.()
  unless before == after_identity, do: raise("root lock/dependency/build identity changed")
  IO.puts("ROOT IDENTITY UNCHANGED: #{inspect(after_identity)}")
end
