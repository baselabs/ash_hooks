# Used by `mix format`. `locals_without_parens` lists ash_hooks' own DSL calls
# and is exported to consumers that add `:ash_hooks` to their `import_deps`.
spark_locals_without_parens = [
  webhooks: 1,
  inbound: 1,
  outbound: 1,
  secret: 1,
  event_id: 1,
  replay_window_seconds: 1,
  signing_mode: 1,
  endpoints: 1
]

[
  import_deps: [:ash, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
