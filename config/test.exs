# The test application is its own Ash host (the resources under test/
# compile in THIS project, so Ash's RequireStringLengthCountConfig
# transformer applies to them). Ash 3.33+ requires every host application
# to choose how string length is counted before any resource compiles —
# the app-level half of GHSA-cwjv-574p-59f6 (grapheme counting let
# unbounded combining-character strings through max_length). :codepoints
# is Ash's recommendation: it bounds value size and matches how the
# sqlite data layer counts, so Elixir-side and storage-side validation
# agree in the fenced-ledger tests. Consumers make their own choice —
# UPGRADING.md documents both values; this file never ships.
import Config

config :ash, default_string_length_count: :codepoints
