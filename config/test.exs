# This test application owns its Ash string-length policy.
# Codepoint counting bounds combining-character input and agrees with SQLite.
# Consumers choose their own mode as described in UPGRADING.md.
# This configuration is excluded from the package.
import Config

config :ash, default_string_length_count: :codepoints
