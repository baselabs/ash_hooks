defmodule AshHooks.Egress.Destination do
  @moduledoc """
  The plain data returned by destination enrollment.

  Build it with `AshHooks.Egress.destination/2`. The scheme, lowercase host,
  explicit port, and escaped path prefix bind every send. `certificate_pin`
  optionally constrains the normally verified TLS leaf. `id` is the
  supplied opaque telemetry identifier. Only controlled tests should enroll with
  `allow_http: true` or `validate_destination: false`.

  Each request checks its effective URL against these fields before network
  I/O. The fields can be stored and reconstructed without an open connection.
  """

  @enforce_keys [:scheme, :host, :port, :path_prefix]
  defstruct [
    :scheme,
    :host,
    :port,
    :path_prefix,
    :certificate_pin,
    :id,
    allow_http: false,
    validate_destination: true
  ]

  @type t :: %__MODULE__{
          scheme: String.t(),
          host: String.t(),
          port: pos_integer(),
          path_prefix: String.t(),
          certificate_pin: term(),
          id: term(),
          allow_http: boolean(),
          validate_destination: boolean()
        }
end
