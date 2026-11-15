defmodule AshHooks.RecordsTest do
  @moduledoc """
  The project's records stay well formed: the roadmap's status board matches its queue, every
  decision record is numbered, titled and carries a current status, and the changelog's release
  headings follow Keep a Changelog and match the project version.

  Each check reads its file from one module attribute; an environment variable names another
  file, so a check can run against a scratch copy.
  """
  use ExUnit.Case, async: true

  @roadmap "docs/ROADMAP.md"
  @adr_dir "docs/adr"
  @changelog "CHANGELOG.md"

  @badges ~w(✅ 🟢 🟡 🔵 ⚪ ⛔)
  @row_id ~r/^[A-Z][A-Z0-9]*(?:-[A-Z0-9.]+)+$/
  @adr_status ~r/^(?:- )?(?:\*\*)?Status:(?:\*\*)? (Proposed|Accepted|Withdrawn|Superseded by (\d{4}))\b/m
  @released ~r/^## \[(\d+\.\d+\.\d+)\] - (\d{4}-\d{2}-\d{2})$/

  describe "roadmap" do
    test "the status board lists every queue row once with a current count" do
      assert_board!(read(@roadmap, "ASH_HOOKS_ROADMAP"))
    end

    test "the board check rejects drift" do
      text = read(@roadmap, "ASH_HOOKS_ROADMAP")
      [first | _] = board_lines(text)
      counts = counts_line(text)

      for broken <- [
            String.replace(text, first <> "\n", "", global: false),
            String.replace(text, counts, Regex.replace(~r/✅ \d+/, counts, "✅ 99")),
            String.replace(text, counts, counts <> "0"),
            String.replace(text, counts, counts <> "\n" <> counts),
            String.replace(text, first, Regex.replace(~r/^\| \S+/, first, "| 🟣"), global: false),
            String.replace(text, first, Regex.replace(~r/^\| \S+/, first, "| ⚠️"), global: false)
          ] do
        refute broken == text
        assert_raise ExUnit.AssertionError, fn -> assert_board!(broken) end
      end
    end
  end

  describe "decision records" do
    test "each record is numbered in sequence, titled and carries a current status" do
      assert_adrs!(adr_files(System.get_env("ASH_HOOKS_ADR_DIR", @adr_dir)))
    end

    test "the record check rejects a malformed record" do
      good = [
        {"0001-first.md", "# 0001 — First\n\n- **Status:** Accepted (2026-08-20)\n"},
        {"0002-second.md", "# 0002 — Second\n\nStatus: Superseded by 0001\n"}
      ]

      assert_adrs!(good)

      for broken <- [
            [hd(good), {"0003-third.md", "# 0003 — Third\n\nStatus: Accepted\n"}],
            [hd(good), {"0002-second.md", "# ADR-0002 — Second\n\nStatus: Accepted\n"}],
            [hd(good), {"0002-second.md", "# 0003 — Second\n\nStatus: Accepted\n"}],
            [hd(good), {"0002-second.md", "# 0002 — Second\n\nAccepted\n"}],
            [hd(good), {"0002-second.md", "# 0002 — Second\n\nStatus: Superseded by 0009\n"}],
            [hd(good), {"0002-second.md", "# 0002 — Second\n\nStatus: Maybe\n"}],
            [hd(good), {"0002-Second.md", "# 0002 — Second\n\nStatus: Accepted\n"}]
          ] do
        assert_raise ExUnit.AssertionError, fn -> assert_adrs!(broken) end
      end
    end
  end

  describe "changelog" do
    test "release headings follow Keep a Changelog and the newest is the project version" do
      assert_changelog!(read(@changelog, "ASH_HOOKS_CHANGELOG"), release_build?())
    end

    test "the changelog check rejects a malformed heading or a stray development section" do
      version = Mix.Project.config()[:version]
      tag = "v#{version}"

      released =
        "## [#{version}] - 2026-11-15\n\n- A change.\n\n[#{version}]: https://example.test/#{tag}\n"

      building = "## [Unreleased]\n\n- A fix.\n\n" <> released
      head = "# Changelog\n\n"

      assert_changelog!(head <> released, true)
      assert_changelog!(head <> building, false)

      for {text, release_build?} <- [
            {head <> building, true},
            {head <> String.replace(released, "] - 2026-11-15", "] (November 15, 2026)"), false},
            {head <> String.replace(released, "## [#{version}]", "## [0.0.1]"), false},
            {head <> released <> "\n## [Unreleased]\n", false},
            {head <> released <> "\n" <> released, false},
            {head <>
               String.replace(released, "\n[#{version}]: https://example.test/#{tag}\n", "\n"),
             false},
            {String.replace(head <> released, "# Changelog", "# Changes"), false}
          ] do
        assert_raise ExUnit.AssertionError, fn -> assert_changelog!(text, release_build?) end
      end
    end
  end

  defp assert_board!(text) do
    rows = queue_ids(text)
    board = board_lines(text)
    statuses = Enum.map(board, &cells/1)
    named = Enum.map(statuses, &Enum.at(&1, 1))

    assert rows != [], "#{@roadmap}: no queue rows"
    assert Enum.uniq(rows) == rows, "#{@roadmap}: a queue ID appears twice"
    assert Enum.all?(rows, &Regex.match?(@row_id, &1)), "#{@roadmap}: a queue ID is malformed"

    assert Enum.sort(named) == Enum.sort(rows),
           "#{@roadmap}: board rows #{inspect(named -- rows)} and queue rows #{inspect(rows -- named)} differ"

    assert length(board) == length(rows),
           "#{@roadmap}: the board has #{length(board)} lines for #{length(rows)} rows"

    for [status, id | _] <- statuses,
        do: assert(status in @badges, "#{@roadmap}: #{id} has status #{status}")

    counted = Enum.frequencies(Enum.map(statuses, &hd/1))

    expected =
      "Counts: " <> Enum.map_join(@badges, " · ", &"#{&1} #{Map.get(counted, &1, 0)}")

    lines =
      text
      |> board_section()
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "Counts:"))

    assert lines == [expected], "#{@roadmap}: counts line must be exactly #{inspect(expected)}"
  end

  defp board_section(text) do
    case String.split(text, ["<!-- status-board:start -->", "<!-- status-board:end -->"]) do
      [_, board, _] -> board
      _ -> flunk("#{@roadmap}: status board markers missing or repeated")
    end
  end

  defp board_lines(text) do
    for line <- String.split(board_section(text), "\n"),
        String.starts_with?(line, "|"),
        [first | _] = row = cells(line),
        length(row) == 4,
        first not in ["Status", "Badge"],
        not String.starts_with?(first, "---"),
        do: line
  end

  defp counts_line(text),
    do:
      text
      |> board_section()
      |> String.split("\n")
      |> Enum.find(&String.starts_with?(&1, "Counts:"))

  defp queue_ids(text) do
    case String.split(text, "| ID | Outcome | Acceptance | Waits on |") do
      [_, table] ->
        for line <- String.split(table, "\n"),
            String.starts_with?(line, "|"),
            [id | _] = cells(line),
            not String.starts_with?(id, "---"),
            do: id

      _ ->
        flunk("#{@roadmap}: one queue table with ID, Outcome, Acceptance and Waits on")
    end
  end

  defp cells(line) do
    line |> String.trim() |> String.trim("|") |> String.split("|") |> Enum.map(&String.trim/1)
  end

  defp adr_files(dir) do
    for path <- dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort(),
        do: {Path.basename(path), File.read!(path)}
  end

  defp assert_adrs!(files) do
    assert files != [], "no decision records"
    numbers = for {name, _} <- files, do: number!(name)

    assert numbers == Enum.to_list(1..length(numbers)),
           "decision records are not numbered 0001 upward without gaps"

    for {name, text} <- files do
      number = String.slice(name, 0, 4)
      [heading | _] = String.split(text, "\n", parts: 2)

      assert Regex.match?(~r/^# #{number} — \S/u, heading),
             "#{name}: heading must be `# #{number} — Title`"

      case Regex.run(@adr_status, text) do
        [_, _, superseded_by] ->
          assert String.to_integer(superseded_by) in numbers,
                 "#{name}: superseded by a missing record"

        [_, _] ->
          :ok

        nil ->
          flunk(
            "#{name}: no `Status:` line naming Proposed, Accepted, Withdrawn or Superseded by NNNN"
          )
      end
    end
  end

  defp number!(name) do
    case Regex.run(~r/^(\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.md$/, name) do
      [_, number] -> String.to_integer(number)
      nil -> flunk("#{name}: decision record files are named NNNN-lowercase-slug.md")
    end
  end

  # One leading `## [Unreleased]` section is allowed while a release is being
  # built and never on a release tag build.
  defp assert_changelog!(text, release_build?) do
    version = Mix.Project.config()[:version]

    assert String.starts_with?(text, "# Changelog\n"),
           "#{@changelog}: first line must be `# Changelog`"

    headings = Regex.scan(~r/^## .*$/m, text) |> List.flatten()

    {development, released} =
      case headings do
        ["## [Unreleased]" | rest] -> {true, rest}
        rest -> {false, rest}
      end

    refute development and release_build?,
           "#{@changelog}: an Unreleased section on a release tag build"

    versions =
      for heading <- released do
        case Regex.run(@released, heading) do
          [_, released_version, date] ->
            assert {:ok, _} = Date.from_iso8601(date),
                   "#{@changelog}: #{heading} has no valid date"

            released_version

          nil ->
            flunk("#{@changelog}: #{inspect(heading)} is not `## [X.Y.Z] - YYYY-MM-DD`")
        end
      end

    assert versions != [] and hd(versions) == version,
           "#{@changelog}: the newest release must be the project version #{version}"

    assert versions == Enum.sort(versions, &(Version.compare(&1, &2) == :gt)),
           "#{@changelog}: releases must be unique and newest first"

    for released_version <- versions,
        do:
          assert(
            Regex.match?(~r/^\[#{Regex.escape(released_version)}\]: \S+$/m, text),
            "#{@changelog}: no link for #{released_version}"
          )
  end

  defp release_build?, do: System.get_env("GITHUB_REF_TYPE") == "tag"

  defp read(path, env), do: File.read!(System.get_env(env, path))
end
