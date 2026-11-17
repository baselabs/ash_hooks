defmodule AshHooks.PublicationDashesTest do
  use ExUnit.Case, async: false

  @script Path.expand("../../scripts/check-document-dashes.py", __DIR__)

  # The checker exempts ExDoc's separator only before this project's own
  # "<name> v<version>" label, read from the project configuration.
  @version Mix.Project.config()[:version]
  @label "#{Mix.Project.config()[:name]} v#{@version}"

  test "both dashes fail in archives, HTML and EPUB but repository-only text passes" do
    tree = Path.join(System.tmp_dir!(), "publication_dashes_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)

    for codepoint <- [0x2013, 0x2014], surface <- ["package", "html", "epub", "repository"] do
      {output, status} =
        System.cmd("python3", ["-c", fixture(), tree, surface, Integer.to_string(codepoint)],
          stderr_to_stdout: true
        )

      assert status == 0, output

      {output, status} =
        System.cmd(
          "python3",
          [
            @script,
            "--package",
            Path.join(tree, "package.tar"),
            "--docs",
            Path.join(tree, "docs")
          ],
          stderr_to_stdout: true
        )

      if surface == "repository" do
        assert {output, status} == {"", 0}
      else
        assert status == 1
        assert output =~ ":2"
        refute output =~ <<codepoint::utf8>>
      end
    end
  end

  test "only ExDoc's final project separator is exempt from generated HTML" do
    tree = Path.join(System.tmp_dir!(), "publication_template_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)
    page = Path.join(tree, "page.html")
    dash = <<0x2014::utf8>>
    project = ~s(<meta name="project" content="#{@label}">)
    title = "<title>Guide #{dash} #{@label}</title>"
    original = "#{project}\n#{title}\n<body>plain</body>"
    File.write!(page, original)
    assert {"", 0} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)

    assert File.read!(page) == original

    for codepoint <- [0x2013, 0x2014], label <- ["AshHooks.Module", "An extra title"] do
      authored = <<codepoint::utf8>>
      title = "<title>#{label} #{authored} text #{dash} #{@label}</title>"
      File.write!(page, "#{project}\n#{title}\n<body>#{authored}</body>")
      {output, status} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)
      assert status == 1
      assert output =~ "#{page}:2"
      assert output =~ "#{page}:3"
      refute output =~ authored
    end

    for title <- [
          "<title>Guide #{dash} OtherProject v#{@version}</title>",
          "<title>Guide #{dash} AshHooks v0.0.0</title>",
          "<title>Guide #{dash} #{@label} suffix</title>",
          "<title>OtherProject v#{@version} #{dash} Documentation</title>",
          "<title>AshHooks v0.0.0 #{dash} Documentation</title>"
        ] do
      File.write!(page, "#{project}\n#{title}")
      {output, status} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)
      assert status == 1
      assert output =~ "#{page}:2"
    end
  end

  test "both ExDoc template forms use the build project and version" do
    {root, docs, identity} = project_fixture()
    page = Path.join(docs, "index.html")
    dash = <<0x2014::utf8>>
    metadata = ~s(<meta name="project" content="#{identity}">)

    for html <- [
          "#{metadata}\n<title>Guide #{dash} #{identity}</title>",
          "<title>#{identity} #{dash} Documentation</title>"
        ] do
      File.write!(page, html)
      assert {"", 0} = check_docs(root, docs)
      assert File.read!(page) == html
    end
  end

  test "template exceptions reject foreign identities and authored separators" do
    {root, docs, identity} = project_fixture()
    page = Path.join(docs, "index.html")
    dash = <<0x2014::utf8>>

    for foreign <- ["OtherProject v9.8.7", "Consumer Guide v0.0.0"],
        title <- ["Guide #{dash} #{foreign}", "#{foreign} #{dash} Documentation"] do
      File.write!(page, ~s(<meta name="project" content="#{foreign}">\n<title>#{title}</title>))
      {output, status} = check_docs(root, docs)
      assert status == 1
      assert output =~ "#{page}:2"
    end

    for codepoint <- [0x2013, 0x2014],
        title <- [
          "Extra #{<<codepoint::utf8>>} title #{dash} #{identity}",
          "#{identity} #{dash} Documentation #{<<codepoint::utf8>>} extra",
          "Prefix #{dash} #{identity} #{dash} Documentation"
        ] do
      File.write!(page, "<title>#{title}</title>")
      {output, status} = check_docs(root, docs)
      assert status == 1
      assert output =~ "#{page}:1"
    end
  end

  defp project_fixture do
    root = Path.join(System.tmp_dir!(), "publication_project_#{Ash.UUID.generate()}")
    docs = Path.join(root, "doc")
    File.mkdir_p!(docs)
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "mix.exs"), """
    defmodule PublicationProject do
      use Mix.Project
      def project, do: [app: :publication_fixture, name: "Consumer Guide", version: "9.8.7"]
    end
    """)

    {root, docs, "Consumer Guide v9.8.7"}
  end

  defp check_docs(root, docs) do
    System.cmd("python3", [@script, "--docs", docs], cd: root, stderr_to_stdout: true)
  end

  test "the HTML template exception does not exempt an EPUB member" do
    tree = Path.join(System.tmp_dir!(), "publication_epub_#{Ash.UUID.generate()}")
    File.mkdir_p!(tree)
    on_exit(fn -> File.rm_rf!(tree) end)
    archive = Path.join(tree, "guide.epub")
    dash = <<0x2014::utf8>>
    project = ~s(<meta name="project" content="#{@label}">)
    title = "<title>Guide #{dash} #{@label}</title>"

    assert {:ok, _} =
             :zip.create(String.to_charlist(archive), [
               {~c"chapter.xhtml", "#{project}\n#{title}"}
             ])

    {output, status} = System.cmd("python3", [@script, "--docs", tree], stderr_to_stdout: true)
    assert status == 1
    assert output =~ "#{archive}/chapter.xhtml:2"
  end

  defp fixture do
    ~S"""
    import io, pathlib, sys, tarfile, zipfile
    root, surface, codepoint = pathlib.Path(sys.argv[1]), sys.argv[2], int(sys.argv[3])
    text = ("first\ntext " + chr(codepoint) + " here\n").encode()
    clean = b"first\nplain text\n"
    contents = io.BytesIO()
    with tarfile.open(fileobj=contents, mode="w:gz") as archive:
        data = text if surface == "package" else clean
        member = tarfile.TarInfo("lib/example.ex")
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
    with tarfile.open(root / "package.tar", "w") as archive:
        data = contents.getvalue()
        member = tarfile.TarInfo("contents.tar.gz")
        member.size = len(data)
        archive.addfile(member, io.BytesIO(data))
    docs = root / "docs"
    docs.mkdir(exist_ok=True)
    (docs / ".build.epub").write_text("reference.epub\n")
    (docs / "index.html").write_bytes(text if surface == "html" else clean)
    with zipfile.ZipFile(docs / "reference.epub", "w") as book:
        book.writestr("EPUB/index.xhtml", text if surface == "epub" else clean)
    (root / "repository-only.txt").write_bytes(text)
    """
  end
end
