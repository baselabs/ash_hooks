# Repo-local configuration for ash_hooks' own development/test app.
# NEVER shipped: the package files list in mix.exs excludes config/, and
# the library itself writes no `:ash` configuration — consumers own that
# (locked by test/ash_hooks/ash_config_ownership_test.exs).
import Config

if config_env() == :test do
  import_config "test.exs"
end
