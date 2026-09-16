# Repo-local configuration for ash_hooks' own development/test app.
# NEVER shipped: the package files list in mix.exs excludes config/, and
# the library itself writes no `:ash` configuration — consumers own that
# (locked by test/ash_hooks/ash_config_ownership_test.exs).
import Config

# Repo-local OTP guard (config/ is never shipped — consumers are
# unaffected; the package's Elixir floor lives in mix.exs). System
# .version/0 does NOT encode the OTP build: the same Elixir built on a
# different OTP passes Mix's check while compiling incompatible BEAMs, so
# the running OTP is asserted here, in code, before anything compiles.
# The allowlist is exactly the set of OTP releases the CI matrix tests —
# it grows only in the same commit that adds the CI leg. to_string/1 is
# mandatory — :erlang.system_info(:otp_release) returns a charlist,
# which can never equal a binary and would make the assert raise
# unconditionally.
supported_otp_releases = ["28", "29"]
running_otp = to_string(:erlang.system_info(:otp_release))

if running_otp not in supported_otp_releases do
  raise "ash_hooks development requires Erlang/OTP #{Enum.join(supported_otp_releases, " or ")}; running #{running_otp} (Elixir #{System.version()}, code root #{:code.root_dir()})."
end

if config_env() == :test do
  import_config "test.exs"
end
