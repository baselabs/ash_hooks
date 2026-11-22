defmodule AshHooks.Egress.Destination do
  @moduledoc """
  An enrolled destination's plain, host-persisted data.

  Build it with `AshHooks.Egress.destination/2`. The scheme, lowercase host,
  explicit port, and escaped path prefix bind every send. `certificate_pin`
  optionally constrains the normally verified TLS leaf. `id` is the host's
  opaque telemetry identifier. Only controlled tests should enroll with
  `allow_http: true` or `validate_destination: false`.

  This struct is enrollment data, not a credential or an admission decision.
  The host controls its creation, storage, and selection for each request.
  """

  @enforce_keys [:scheme, :host, :port, :path_prefix]
  defstruct [:scheme, :host, :port, :path_prefix, :certificate_pin, :id,
             allow_http: false, validate_destination: true]

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
