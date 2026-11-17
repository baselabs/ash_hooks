defmodule AshHooks.DocumentationContractTest do
  use ExUnit.Case, async: false

  alias AshHooks.Test.Documentation, as: Docs
  alias AshHooks.Test.DocumentationRuns

  test "every shipped block has a specific disposition and consumer formatting" do
    blocks = Docs.validate_manifest!(Docs.documents())
    assert :ok = Docs.validate_format!(blocks)
  end

  test "the disposition contract rejects missing, malformed, duplicate, and orphan markers" do
    tested = "<!-- tested: checked -->\n```elixir\n:ok\n```\n"
    assert [%{name: "checked", reason: nil}] = Docs.validate_manifest!([{"guide", tested}])

    for mutation <- [
          "```sql\nSELECT 1;\n```",
          String.replace(tested, "tested: checked", "tested: Bad Name"),
          String.replace(tested, "tested:", "tested :"),
          tested <> tested,
          tested <> "\n<!-- tested: orphan -->\n",
          "<!-- not-run:  -->\n```sql\nSELECT 1;\n```",
          "<!-- not-run: example -->\n```sql\nSELECT 1;\n```",
          "<!-- tested: json -->\n```json\n{}\n```"
        ] do
      assert_raise RuntimeError, fn -> Docs.validate_manifest!([{"guide", mutation}]) end
    end

    assert_raise RuntimeError, ~r/duplicate/, fn ->
      Docs.validate_manifest!([{"one", tested}, {"two", tested}])
    end

    assert [%{reason: "Requires the host project configuration."}] =
             Docs.validate_manifest!([
               {"guide",
                "<!-- not-run: Requires the host project configuration. -->\n```sh\ntrue\n```"}
             ])
  end

  test "execution accounting requires the current run and rejects extra claims" do
    blocks =
      Docs.validate_manifest!([{"guide", "<!-- tested: required -->\n```elixir\n:ok\n```"}])

    assert :ok = Docs.validate_execution!(blocks, ["required"])

    for completed <- [[], ["other"], ["required", "orphan"]] do
      assert_raise RuntimeError, ~r/executed examples differ/, fn ->
        Docs.validate_execution!(blocks, completed)
      end
    end
  end

  test "required qualification rejects skipped, excluded, failed and unexecuted runs" do
    tree = Path.join(System.tmp_dir!(), "documentation_run_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    for mode <- [:passed, :skipped, :excluded, :failed, :unexecuted] do
      script = Path.join(tree, "#{mode}.exs")
      File.write!(script, qualification_script(mode))

      {output, status} =
        System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ [script],
          stderr_to_stdout: true
        )

      if mode == :passed do
        assert status == 0, output
      else
        refute status == 0, "#{mode} incorrectly qualified: #{output}"
        assert output =~ "executed examples differ: missing [\"required\"]", output
      end
    end
  end

  defp qualification_script(mode) do
    tag = if(mode == :skipped, do: "@tag skip: true", else: "@tag omitted: true")
    exclusions = if(mode == :excluded, do: "[omitted: true]", else: "[]")

    body =
      if mode == :unexecuted,
        do: ":ok",
        else:
          ~s|Docs.run!(%{file: "fixture", line: 1, language: "sh", name: "required", code: "true"}, File.cwd!())|

    failure = if(mode == :failed, do: ~s|flunk("executed but failed")|, else: ":ok")

    """
    {:ok, _tracker} = AshHooks.Test.DocumentationRuns.start_link([])
    ExUnit.start(autorun: false, exclude: #{exclusions}, formatters: [ExUnit.CLIFormatter, AshHooks.Test.DocumentationFormatter])
    ExUnit.after_suite(fn _ ->
      AshHooks.Test.Documentation.validate_run!([%{name: "required", reason: nil}])
    end)
    defmodule QualificationFixture do
      use ExUnit.Case
      alias AshHooks.Test.Documentation, as: Docs
      setup context do
        Docs.track_test(context)
      end
      #{tag}
      test "the required runner" do
        #{body}
        #{failure}
      end
    end
    ExUnit.run()
    """
  end

  test "only successful runners contribute their names to the current run" do
    {:ok, tracker} = GenServer.start_link(AshHooks.Test.DocumentationRuns, [])
    on_exit(fn -> if Process.alive?(tracker), do: GenServer.stop(tracker) end)

    for name <- [:passed, :failed, :skipped] do
      assert :ok = GenServer.call(tracker, {:completed, {__MODULE__, name}, [to_string(name)]})
    end

    GenServer.call(tracker, {:finished, %{state: nil, module: __MODULE__, name: :passed}})

    GenServer.call(
      tracker,
      {:finished, %{state: {:failed, []}, module: __MODULE__, name: :failed}}
    )

    GenServer.call(
      tracker,
      {:finished, %{state: {:skipped, "reason"}, module: __MODULE__, name: :skipped}}
    )

    assert ["passed"] = GenServer.call(tracker, :completed_names)

    completed = DocumentationRuns.completed_names()
    blocks = for name <- completed, do: %{name: name, reason: nil}
    assert :ok = Docs.validate_run!(blocks)
  end

  test "template operands fail while literals, comments and valid operators remain valid" do
    for {language, code} <- [
          {"sql", "UPDATE deliveries SET org_id = <derived per row>;"},
          {"sh", "cat <derived per row>"},
          {"elixir", "org_id = <derived per row>"}
        ] do
      assert_raise RuntimeError, fn -> Docs.validate_placeholders!(block(language, code)) end
    end

    for {language, code} <- [
          {"elixir", ~s(value = {"...", "TODO", "<derived per row>"})},
          {"sql", ~s(SELECT '...', 'TODO', '<derived per row>', "<column>"; -- <comment>)},
          {"sql", "SELECT 1 /* <comment> */ WHERE 1 < 2;"},
          {"sh", ~s(printf '%s' '...' "TODO" '<derived per row>' # <comment>)}
        ] do
      assert :ok = Docs.validate_placeholders!(block(language, code))
    end
  end

  test "the formatter uses dependency and package exports at the consumer line length" do
    options = Docs.formatter_options()
    assert options[:line_length] == 98
    assert {:inbound, 2} in options[:locals_without_parens]
    assert :ok = Docs.validate_format!([block("elixir", ":ok\n"), block("sql", "SELECT 1")])

    for code <- ["value=:ok\n", "defmodule Broken do\n"] do
      assert_raise RuntimeError, fn -> Docs.validate_format!([block("elixir", code)]) end
    end
  end

  @tag skip: System.get_env("ASH_HOOKS_NO_OPTIONAL") == "1"
  test "consumer formatting reads Phoenix exports from the dependency" do
    path = Map.fetch!(Mix.Project.deps_paths(), :phoenix)
    {phoenix, _} = Code.eval_file(Path.join(path, ".formatter.exs"))
    exports = phoenix[:export][:locals_without_parens]
    assert exports != []
    assert exports -- Docs.formatter_options()[:locals_without_parens] == []
  end

  @tag skip: System.get_env("ASH_HOOKS_NO_OPTIONAL") == "1"
  test "consumer DSL calls reject parentheses as well as spacing mutations" do
    assert :ok = Docs.validate_format!([block("elixir", "plug Plug.Parsers, parsers: [:json]\n")])

    for code <- ["plug(Plug.Parsers, parsers: [:json])\n", "value=:ok\n"] do
      assert_raise RuntimeError, fn -> Docs.validate_format!([block("elixir", code)]) end
    end
  end

  test "dash policy covers the package manifest and excludes repository-only files" do
    shipped = Enum.map(Docs.package_files(), &{&1, File.read!(&1)})
    refute Enum.any?(shipped, fn {path, _} -> String.starts_with?(path, "test/") end)
    assert :ok = Docs.validate_dashes!(shipped)

    for codepoint <- [0x2013, 0x2014] do
      dash = <<codepoint::utf8>>

      assert_raise RuntimeError, "README.md:2", fn ->
        Docs.validate_dashes!([{"README.md", "first\nshipped #{dash} text"}])
      end

      # The source list comes from the package, not from every tracked file.
      files = [{"README.md", "plain"}, {"test/repository_only.exs", dash}]

      assert :ok =
               Docs.validate_dashes!(Enum.filter(files, &(elem(&1, 0) in Docs.package_files())))
    end
  end

  defp block(language, code), do: %{file: "guide", line: 1, language: language, code: code}
end
