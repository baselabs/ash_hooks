defmodule AshHooks.DocsArchiveTest do
  use ExUnit.Case, async: true

  @script Path.expand("../../scripts/check-docs-archive.py", __DIR__)
  @stamp Path.expand("../../scripts/stamp-docs-release.py", __DIR__)
  @writer """
  import base64, io, sys, tarfile
  path, rest = sys.argv[1], sys.argv[2:]
  with tarfile.open(path, "w:gz") as packed:
      for name, data in zip(rest[::2], rest[1::2]):
          info = tarfile.TarInfo(name)
          content = base64.b64decode(data)
          info.size = len(content)
          packed.addfile(info, io.BytesIO(content))
  """

  # A repository whose default branch is first -> second, with a side commit
  # off that history, stands in for the dispatched checkout.
  setup do
    tree = Path.join(System.tmp_dir!(), "docs_archive_#{Ash.UUID.generate()}")
    docs = Path.join(tree, "doc")
    repo = Path.join(tree, "repo")
    File.mkdir_p!(Path.join(docs, "dist"))
    File.mkdir_p!(Path.join(docs, ".hidden"))
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf!(tree) end)
    File.write!(Path.join(docs, "index.html"), "index")
    File.write!(Path.join(docs, "readme.html"), "readme")
    File.write!(Path.join(docs, "readme.md"), "readme")
    File.write!(Path.join(docs, "dist/app.js"), "app")
    # mix hex.publish leaves names that start with a dot out of the archive.
    File.write!(Path.join(docs, ".build"), "manifest")
    File.write!(Path.join(docs, ".hidden/page.html"), "hidden")

    git(repo, ["init", "--quiet", "--initial-branch", "main"])
    first = commit(repo, "first")
    second = commit(repo, "second")
    git(repo, ["switch", "--quiet", "--create", "side", first])
    side = commit(repo, "side")
    git(repo, ["switch", "--quiet", "main"])

    stamp = ["-I", @stamp, docs, "--version", "3.4.0", "--commit", second]
    {output, status} = System.cmd("python3", stamp, stderr_to_stdout: true)

    assert status == 0, output
    %{tree: tree, docs: docs, repo: repo, first: first, second: second, side: side}
  end

  test "release.json names the package, version and building commit", context do
    assert Jason.decode!(File.read!(Path.join(context.docs, "release.json"))) == %{
             "package" => "ash_hooks",
             "version" => "3.4.0",
             "commit" => context.second
           }
  end

  test "an archive of exactly the tree's visible regular files passes", context do
    {output, status} = check(context, archive(context, members(context)))
    assert status == 0, output
    assert output =~ "DOCS OK: 5 regular files"
    assert output =~ ~r/SHA256: [0-9a-f]{64}/
  end

  test "an EPUB is refused because it embeds the build time", context do
    File.write!(Path.join(context.docs, "AshHooks.epub"), "book")
    entries = members(context) ++ [{"AshHooks.epub", "book"}]
    {output, status} = check(context, archive(context, entries))
    assert status == 1
    assert output =~ "EPUB embeds the build time"
  end

  test "differing bytes, omitted files, extra and unsafe members are refused", context do
    cases = [
      {[{"index.html", "other"} | tl(members(context))], "bytes differ from source"},
      {Enum.drop(members(context), -1), "omits source files"},
      {[{".build", "manifest"} | members(context)], "has no source"},
      {[{"../index.html", "index"} | members(context)], "Unsafe docs archive member"},
      {[{"3.4.0/index.html", "index"} | members(context)], "cannot be semantic versions"},
      {[{"index.html", "index"} | members(context)], "Duplicate docs archive member"}
    ]

    for {entries, message} <- cases do
      {output, status} = check(context, archive(context, entries))
      assert status == 1, message
      assert output =~ message
    end
  end

  test "a built archive must name the building commit", context do
    {output, status} = check(context, archive(context, members(context)), context.first)
    assert status == 1
    assert output =~ "not the building commit #{context.first}"
  end

  test "served docs naming the dispatched commit or an ancestor publish that commit", context do
    for named <- [context.second, context.first] do
      {output, status} = served(context, archive(context, served_members(context, named)))
      assert status == 0, output
      assert output =~ "PUBLISHED COMMIT: #{named}"
    end
  end

  test "served docs with an EPUB from an earlier build still pass", context do
    entries = [{"AshHooks.epub", "book"} | served_members(context, context.second)]
    {output, status} = served(context, archive(context, entries))
    assert status == 0, output
  end

  test "served docs off the default branch, unknown or unnamed are refused", context do
    unknown = String.duplicate("0", 40)
    named = served_members(context, context.second)
    without = Enum.reject(named, &(elem(&1, 0) == "release.json"))
    other_version = {"release.json", release_json(context.second, "3.3.0")}

    cases = [
      {served_members(context, context.side), "off the default branch history"},
      {served_members(context, unknown), "which this repository does not have"},
      {without, "carries no top-level release.json"},
      {[other_version | without], "does not name ash_hooks 3.4.0"},
      {[{"release.json", "[]"} | without], "does not name ash_hooks 3.4.0"}
    ]

    for {entries, message} <- cases do
      {output, status} = served(context, archive(context, entries))
      assert status == 1, message
      assert output =~ message
    end
  end

  test "served docs without entry pages or with unsafe members are refused", context do
    named = served_members(context, context.second)

    cases = [
      {Enum.reject(named, &(elem(&1, 0) == "readme.html")), "requires top-level"},
      {[{"../index.html", "index"} | named], "Unsafe docs archive member"},
      {[{"index.html", "index"} | named], "Duplicate docs archive member"}
    ]

    for {entries, message} <- cases do
      {output, status} = served(context, archive(context, entries))
      assert status == 1, message
      assert output =~ message
    end
  end

  defp members(%{docs: docs}) do
    for name <- ["index.html", "readme.html", "readme.md", "dist/app.js", "release.json"],
        do: {name, File.read!(Path.join(docs, name))}
  end

  # Served docs come from some earlier build: other index bytes, their own
  # release.json.
  defp served_members(context, commit) do
    Enum.reject(members(context), &(elem(&1, 0) in ["index.html", "release.json"])) ++
      [{"index.html", "an earlier build"}, {"release.json", release_json(commit, "3.4.0")}]
  end

  defp release_json(commit, version),
    do: Jason.encode!(%{"package" => "ash_hooks", "version" => version, "commit" => commit})

  # Python's tarfile writes every member name as given, including the unsafe
  # and duplicate names the checker must refuse.
  defp archive(%{tree: tree}, entries) do
    path = Path.join(tree, "docs-#{System.unique_integer([:positive])}.tar.gz")

    args = Enum.flat_map(entries, fn {name, bytes} -> [name, Base.encode64(bytes)] end)

    {output, status} =
      System.cmd("python3", ["-I", "-c", @writer, path | args], stderr_to_stdout: true)

    assert status == 0, output
    path
  end

  defp check(context, archive, commit \\ nil) do
    args = ["--version", "3.4.0", "--commit", commit || context.second, archive, context.docs]
    System.cmd("python3", ["-I", @script | args], stderr_to_stdout: true)
  end

  defp served(context, archive) do
    args = ["--served", "--repo", context.repo, "--version", "3.4.0", "--commit", context.second]
    System.cmd("python3", ["-I", @script | args ++ [archive]], stderr_to_stdout: true)
  end

  defp commit(repo, message) do
    git(repo, ["commit", "--quiet", "--allow-empty", "--message", message])
    repo |> git(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git(repo, args) do
    identity = ["-c", "user.name=test", "-c", "user.email=test@example.invalid"]
    {output, 0} = System.cmd("git", ["-C", repo | identity ++ args], stderr_to_stdout: true)
    output
  end
end
