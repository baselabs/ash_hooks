defmodule AshHooks.ReleaseRecordTest do
  use ExUnit.Case, async: true

  @state Path.expand("../../scripts/hex-release-state.py", __DIR__)
  @notes Path.expand("../../scripts/release-notes.py", __DIR__)

  # Loads the state script and prints decide/3 for one release record. decide
  # makes no request, so served docs are kept without fetching their bytes.
  @decide """
  import importlib.util, json, sys
  sys.dont_write_bytecode = True
  spec = importlib.util.spec_from_file_location("state", sys.argv[1])
  state = importlib.util.module_from_spec(spec)
  spec.loader.exec_module(state)
  record = json.loads(sys.argv[2])
  try:
      print(json.dumps(state.decide(record, "3.4.0", state.Path(sys.argv[3])), sort_keys=True))
  except ValueError as error:
      print(f"refused: {error}")
  """

  setup do
    tree = Path.join(System.tmp_dir!(), "release_record_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)
    package = Path.join(tree, "ash_hooks-3.4.0.tar")
    File.write!(package, "package")
    checksum = :crypto.hash(:sha256, "package") |> Base.encode16(case: :lower)
    %{tree: tree, package: package, checksum: checksum}
  end

  test "a missing release uploads both archives", context do
    assert decide(context, nil) == ~s({"docs": "upload", "package": "upload"})
  end

  test "a served package with the inspected bytes keeps served docs and uploads missing docs",
       context do
    served = %{"checksum" => context.checksum, "has_docs" => true}
    assert decide(context, served) == ~s({"docs": "skip", "package": "skip"})

    missing = %{served | "has_docs" => false}
    assert decide(context, missing) == ~s({"docs": "upload", "package": "skip"})
  end

  test "other package bytes or an indefinite docs state refuse", context do
    assert decide(context, %{"checksum" => String.duplicate("0", 64), "has_docs" => true}) =~
             "refused: hex.pm serves ash_hooks 3.4.0 with other bytes"

    assert decide(context, %{"checksum" => context.checksum}) =~
             "refused: hex.pm returned no definite documentation state"
  end

  test "one nonempty changelog section qualifies", context do
    changelog = changelog(context, "## [3.4.0] - 2026-11-20\n\n### Added\n\n- Dispatch.\n")
    {output, status} = notes(["3.4.0", "--changelog", changelog])
    assert status == 0, output
    assert output =~ "CHANGELOG OK: one nonempty section for 3.4.0"
  end

  test "a missing, empty or duplicated changelog section refuses", context do
    for text <- [
          "## [3.3.0] - 2026-11-17\n\n- Earlier.\n",
          "## [3.4.0] - 2026-11-20\n\n### Added\n",
          "## [3.4.0] - 2026-11-20\n\n- One.\n\n## [3.4.0] - 2026-11-20\n\n- Two.\n"
        ] do
      {output, status} = notes(["3.4.0", "--changelog", changelog(context, text)])
      assert status == 1, text
      assert output =~ "changelog section for 3.4.0 is missing, duplicated or empty"
    end
  end

  defp decide(context, record) do
    args = ["-I", "-c", @decide, @state, Jason.encode!(record), context.package]
    {output, 0} = System.cmd("python3", args, stderr_to_stdout: true)
    String.trim(output)
  end

  defp changelog(%{tree: tree}, text) do
    path = Path.join(tree, "CHANGELOG-#{System.unique_integer([:positive])}.md")
    File.write!(path, "# Changelog\n\n" <> text)
    path
  end

  defp notes(args), do: System.cmd("python3", ["-I", @notes | args], stderr_to_stdout: true)
end
