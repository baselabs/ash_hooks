# Repo-local configuration for ash_hooks' own development/test app.
# NEVER shipped: the package files list in mix.exs excludes config/, and
# the library itself writes no `:ash` configuration — consumers own that
# (locked by test/ash_hooks/ash_config_ownership_test.exs).
import Config

# This repository requires a supported OTP release before compilation.
# Elixir's version alone does not identify its OTP build.
# This development configuration is excluded from the package.
project_root = Path.expand("..", __DIR__)

tool_version_files =
  [Path.join(project_root, ".tool-versions")] ++
    Path.wildcard(Path.join(project_root, "ci/*/.tool-versions"), match_dot: true)

supported_otp_releases =
  tool_version_files
  |> Enum.flat_map(fn file ->
    file
    |> File.stream!()
    |> Enum.flat_map(fn line ->
      case line |> String.split("#", parts: 2) |> hd() |> String.split() do
        ["erlang" | versions] ->
          Enum.map(versions, fn version -> version |> String.split(".", parts: 2) |> hd() end)

        _ ->
          []
      end
    end)
  end)
  |> Enum.uniq()
  |> Enum.sort_by(&String.to_integer/1)

running_otp = to_string(:erlang.system_info(:otp_release))

if running_otp not in supported_otp_releases do
  raise "ash_hooks development requires Erlang/OTP #{Enum.join(supported_otp_releases, " or ")}; running #{running_otp} (Elixir #{System.version()}, code root #{:code.root_dir()})."
end

if config_env() == :test do
  import_config "test.exs"
end
