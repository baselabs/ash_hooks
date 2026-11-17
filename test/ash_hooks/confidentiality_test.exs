defmodule AshHooks.ConfidentialityTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/check-confidentiality.sh", __DIR__)

  setup do
    tree = Path.join(System.tmp_dir!(), "public_scan_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)
    %{tree: tree}
  end

  test "hits use fixed, case-insensitive whole words and reveal only rule numbers", %{tree: tree} do
    path = Path.join(tree, "document.txt")
    File.write!(path, "typel-7\nL-7\ncedarhost-edge\ncedarhost_suffix\ncedarhost2\n[bracket.token]\n")
    {output, status} = run(tree, "l-7\ncedarhost\n[bracket.token]")
    assert status == 1
    assert String.split(output, "\n", trim: true) == [
             "#{path}:2 rule-1",
             "#{path}:3 rule-2",
             "#{path}:6 rule-3"
           ]
    for token <- ["l-7", "cedarhost", "bracket.token"], do: refute(String.contains?(output, token))
  end

  test "a clean tree passes, including near matches", %{tree: tree} do
    File.write!(Path.join(tree, "document.txt"), "typel-7 cedarhost_suffix cedarhost2\n")
    assert {"", 0} = run(tree, "l-7\ncedarhost")
  end

  test "missing, empty and blank-line policies fail closed without output", %{tree: tree} do
    for policy <- [nil, "", "\n", "invented\n\nsecond"] do
      assert {"", 2} = run(tree, policy)
    end
  end

  test "the positive control detects a broken control and cleans every temporary file", %{tree: tree} do
    # Mutate the control's input, not the scanner or an external service.
    mutant = Path.join(tree, "control-mutant.sh")
    code = File.read!(@script)
    mutated = String.replace(code, "\"$first\" > \"$work/control\"", "\"unrelated-control-input\" > \"$work/control\"")
    refute mutated == code
    File.write!(mutant, mutated)
    scratch = Path.join(tree, "scratch")
    clean = Path.join(tree, "clean")
    File.mkdir_p!(scratch)
    File.mkdir_p!(clean)

    assert {"", 2} =
             System.cmd("bash", [mutant, "--tree", clean],
               env: [{"PUBLIC_DOCS_DENYLIST", "invented-control-token"}, {"TMPDIR", scratch}],
               stderr_to_stdout: true
             )

    assert File.ls!(scratch) == []
    assert {"", 0} = run(clean, "invented-control-token", [{"TMPDIR", scratch}])
    assert File.ls!(scratch) == []
  end

  test "a synthetic policy finds tracked source without echoing its token" do
    paths = System.cmd("git", ["ls-files", "-z"]) |> elem(0) |> String.split(<<0>>, trim: true)
    {output, status} = run_paths(paths, "AshHooks")
    assert status == 1
    assert output =~ " rule-1"
    refute output =~ "AshHooks"
  end

  defp run_paths(paths, policy) do
    System.cmd("bash", [@script, "--tree" | paths],
      env: [{"PUBLIC_DOCS_DENYLIST", policy}], stderr_to_stdout: true)
  end

  defp run(tree, policy, extra_env \\ []) do
    System.cmd("bash", [@script, "--tree", tree],
      env: [{"PUBLIC_DOCS_DENYLIST", policy} | extra_env],
      stderr_to_stdout: true
    )
  end
end
