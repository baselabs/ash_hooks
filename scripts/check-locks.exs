# Run with the repository's pinned Elixir: elixir scripts/check-locks.exs.
# No dependency resolution or project compilation is needed for the check.
Mix.start()

defmodule LockBytes do
  def main(["--self-test"]), do: self_test()

  def main(paths) do
    paths = if paths == [], do: tracked_locks(), else: paths
    paths = Enum.map(paths, &Path.expand/1)

    temporary(fn work ->
      File.write!(Path.join(work, "mix.exs"), """
      defmodule LockBytesProject do
        use Mix.Project
        def project, do: [app: :lock_bytes, version: "0.0.0", lockfile: "baseline.lock"]
      end
      """)

      Mix.Project.in_project(:lock_bytes, work, fn _ ->
        results = Enum.map(paths, &check/1)
        if Enum.all?(results), do: 0, else: 1
      end)
    end)
  end

  defp tracked_locks do
    {files, 0} = System.cmd("git", ["ls-files", "-z", "--", "*mix.lock*"])
    paths = String.split(files, <<0>>, trim: true)
    if paths == [], do: raise("no committed Mix locks found")
    paths
  end

  defp check(path) do
    lock = Mix.Dep.Lock.read(path)

    # write/2 compares against the project's default lock, even with file: set.
    # Give it a different baseline so it cannot skip serialization. This also
    # forces Mix to write an empty lock. Only disposable files are ever changed.
    baseline = if map_size(lock) == 0, do: "%{force_rewrite: nil}\n", else: "%{}\n"
    File.write!("baseline.lock", baseline)
    Mix.Dep.Lock.write(lock, file: "rewritten.lock")

    if File.read!(path) == File.read!("rewritten.lock") do
      IO.puts("Mix-written lock bytes: #{path}")
      true
    else
      IO.puts(:stderr, "Lock bytes differ from Mix's writer: #{path}")
      false
    end
  end

  defp self_test do
    script = Path.expand(__ENV__.file)

    temporary(fn work ->
      File.write!(Path.join(work, "mix.exs"), """
      defmodule LockBytesProof do
        use Mix.Project
        def project, do: [app: :lock_bytes_proof, version: "0.0.0", deps: [{:jason, "1.4.5"}]]
      end
      """)

      command!("mix", ["deps.get"], work, 0)
      path = Path.join(work, "mix.lock")
      written = File.read!(path)
      command!("elixir", [script, path], work, 0)
      IO.puts("W25 GREEN: the public checker accepts a real Mix-written Hex resolution")

      edited = "\n" <> written
      File.write!(path, edited)
      command!("mix", ["deps.get", "--check-locked"], work, 0)
      if File.read!(path) != edited, do: raise("--check-locked rewrote the proof lock")
      command!("elixir", [script, path], work, 1)
      IO.puts("W25 RED: the public checker rejects hand-edited bytes admitted by --check-locked")
      0
    end)
  end

  defp command!(command, args, directory, expected) do
    {output, status} = System.cmd(command, args, cd: directory, stderr_to_stdout: true)
    IO.write(output)
    if status != expected, do: raise("#{command} exited #{status}, expected #{expected}")
  end

  defp temporary(fun) do
    work =
      Path.join(
        System.tmp_dir!(),
        "mix-lock-bytes-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(work)

    try do
      fun.(work)
    after
      File.rm_rf!(work)
    end
  end
end

System.halt(LockBytes.main(System.argv()))
