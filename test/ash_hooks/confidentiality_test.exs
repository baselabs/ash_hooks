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

    File.write!(
      path,
      "typel-7\nL-7\ncedarhost-edge\ncedarhost_suffix\ncedarhost2\n[bracket.token]\n"
    )

    {output, status} = run(tree, "l-7\ncedarhost\n[bracket.token]")
    assert status == 1

    assert String.split(output, "\n", trim: true) == [
             "#{path}:2 rule-1",
             "#{path}:3 rule-2",
             "#{path}:6 rule-3"
           ]

    for token <- ["l-7", "cedarhost", "bracket.token"],
        do: refute(String.contains?(output, token))
  end

  test "rules never reach grep's arguments", %{tree: tree} do
    # A logging grep first on PATH records every argument list the scanner
    # passes, then runs the real grep. Paths reach it through its environment,
    # so a temporary directory with spaces cannot break the wrapper.
    bin = Path.join(tree, "bin")
    log = Path.join(tree, "grep-arguments.log")
    File.mkdir_p!(bin)
    wrapper = Path.join(bin, "grep")

    File.write!(wrapper, """
    #!/usr/bin/env bash
    printf '%s\\n' "$*" >> "$GREP_ARGUMENTS_LOG"
    exec "$REAL_GREP" "$@"
    """)

    File.chmod!(wrapper, 0o755)
    scanned = Path.join(tree, "scanned")
    File.mkdir_p!(scanned)
    File.write!(Path.join(scanned, "document.txt"), "plain\ninvented-argument-token\n")

    {output, status} =
      System.cmd("bash", [@script, "--tree", scanned],
        env: [
          {"PUBLIC_DOCS_DENYLIST", "invented-argument-token"},
          {"GREP_ARGUMENTS_LOG", log},
          {"REAL_GREP", System.find_executable("grep")},
          {"PATH", bin <> ":" <> System.get_env("PATH")}
        ],
        stderr_to_stdout: true
      )

    assert {output, status} == {"#{Path.join(scanned, "document.txt")}:2 rule-1\n", 1}
    arguments = File.read!(log)
    assert arguments =~ "-aFinw -f "
    refute arguments =~ "invented-argument-token"
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

  test "the positive control detects a broken control and cleans every temporary file", %{
    tree: tree
  } do
    # Mutate the control's input, not the scanner or an external service.
    mutant = Path.join(tree, "control-mutant.sh")
    code = File.read!(@script)

    mutated =
      String.replace(
        code,
        "\"$first\" > \"$work/control\"",
        "\"unrelated-control-input\" > \"$work/control\""
      )

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
    {output, status} = run_paths(paths, "Unreleased")
    assert status == 1
    assert output =~ " rule-1"
    refute output =~ "Unreleased"
  end

  test "publication scanning reads HTML, Markdown and unpacked package files, not ExDoc assets",
       %{
         tree: tree
       } do
    package = Path.join(tree, "package")
    docs = Path.join(tree, "docs")
    File.mkdir_p!(package)
    File.mkdir_p!(docs)
    html = Path.join(docs, "index.html")
    token = "invented-publication-token"
    File.write!(html, "plain HTML")
    File.write!(Path.join(docs, "asset.js"), token)

    for surface <- ["container", "markdown", "html", "package"] do
      File.write!(html, if(surface == "html", do: "first\n#{token}", else: "plain HTML"))

      File.write!(
        Path.join(package, "README.md"),
        if(surface == "package", do: token, else: "plain")
      )

      {output, status} =
        System.cmd("python3", ["-c", publication_fixture(), docs, surface, token],
          stderr_to_stdout: true
        )

      assert status == 0, output

      {output, status} =
        System.cmd("bash", [@script, "--publication", package, docs],
          env: [{"PUBLIC_DOCS_DENYLIST", token}],
          stderr_to_stdout: true
        )

      if surface == "container" do
        assert {output, status} == {"", 0}
      else
        assert status == 1
        assert output =~ " rule-1"
        refute output =~ token
        if surface == "markdown", do: assert(output =~ "reference.md:2 rule-1")
        if surface == "html", do: assert(output =~ "index.html:2 rule-1")
        if surface == "package", do: assert(output =~ "README.md:1 rule-1")
      end
    end
  end

  defp publication_fixture do
    ~S"""
    import pathlib, sys
    docs, surface, token = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
    page = docs / "reference.md"
    page.write_text("first\n" + (token if surface == "markdown" else "plain"))
    """
  end

  @tag :confidentiality
  @tag timeout: 600_000
  test "the configured policy scans tracked source, the archive and generated documentation" do
    {output, status} = System.cmd("bash", [@script], stderr_to_stdout: true)
    assert status == 0, output
    assert output == ""
  end

  defp run_paths(paths, policy) do
    System.cmd("bash", [@script, "--tree" | paths],
      env: [{"PUBLIC_DOCS_DENYLIST", policy}],
      stderr_to_stdout: true
    )
  end

  defp run(tree, policy, extra_env \\ []) do
    System.cmd("bash", [@script, "--tree", tree],
      env: [{"PUBLIC_DOCS_DENYLIST", policy} | extra_env],
      stderr_to_stdout: true
    )
  end
end
