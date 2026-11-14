# Used by `mix format`. `locals_without_parens` lists ash_hooks' own DSL calls
# and is exported to consumers that add `:ash_hooks` to their `import_deps`.
# `mix spark.generate` writes the list from the DSL; `mix spark.check` fails
# when it drifts.
spark_locals_without_parens = [
  body_format: 1,
  custodian: 1,
  default_overlap_seconds: 1,
  deliveries: 1,
  description: 1,
  disabled_value: 1,
  enabled_values: 1,
  endpoint_resource: 1,
  event_id: 1,
  events: 1,
  example: 1,
  failure_share: 1,
  failure_window_seconds: 1,
  filter_attributes: 1,
  inbound: 1,
  inbound: 2,
  ingress_tracking: 1,
  issue_timeout: 1,
  json_decoder: 1,
  key_lifecycle: 1,
  key_registry: 1,
  lease_seconds: 1,
  legacy_key_lifecycle: 1,
  max_overlap_seconds: 1,
  min_attempts: 1,
  outbound: 1,
  outbound: 2,
  pausable: 1,
  paused: 1,
  payload_attribute: 1,
  payload_schema: 1,
  payload_versions: 1,
  previous_secret: 1,
  provider: 1,
  prune_action: 1,
  replay_window_seconds: 1,
  resend_tracking: 1,
  response_capture_attributes: 1,
  scope_identity: 1,
  secret: 1,
  signing_mode: 1,
  status_attribute: 1,
  subscriptions: 1,
  test_tracking: 1,
  version: 1,
  version_pinning: 1,
  warning_interval_seconds: 1,
  warning_min_attempts: 1,
  warning_share: 1
]

[
  import_deps: [:ash, :spark],
  # Keep globs declarative: Igniter reads this config during initialization.
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "scripts/*.exs"],
  excludes: ["test/consumer/{deps,_build}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
