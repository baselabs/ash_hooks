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
  endpoints: 1,
  inbound_delivery: 1,
  scope_identity: 1,
  subscription: 1,
  endpoint_resource: 1,
  endpoint: 1,
  status_attribute: 1,
  enabled_values: 1,
  disabled_value: 1,
  outbound_delivery: 1,
  payload_attribute: 1,
  prune_action: 1
]

[
  import_deps: [:ash, :spark],
  # Keep globs declarative: Igniter reads this config during initialization.
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "scripts/*.exs"],
  excludes: ["test/consumer/{deps,_build}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
