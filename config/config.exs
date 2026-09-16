# Repo-local configuration for ash_hooks' own development/test app.
# NEVER shipped: the package files list in mix.exs excludes config/, and
# the library itself writes no `:ash` configuration — consumers own that
# (locked by test/ash_hooks/ash_config_ownership_test.exs).
import Config

# The OTP half of the toolchain pin (the Elixir half is the exact
# requirement in mix.exs). System.version/0 does NOT encode the OTP build:
# this same Elixir built on a different OTP passes Mix's check while
# compiling incompatible BEAMs, so the running OTP is asserted here, in
# code, before anything compiles. to_string/1 is mandatory —
# :erlang.system_info(:otp_release) returns a charlist, which can never
# equal a binary and would make this assert raise unconditionally.
# LOCKSTEP: "28" tracks .tool-versions and CI's otp-version in ONE commit.
expected_otp = "28"
running_otp = to_string(:erlang.system_info(:otp_release))

if running_otp != expected_otp do
  raise "ash_hooks requires Erlang/OTP #{expected_otp}; running #{running_otp} (Elixir #{System.version()}, code root #{:code.root_dir()})."
end

if config_env() == :test do
  import_config "test.exs"
end
