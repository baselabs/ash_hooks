defmodule AshHooks.Egress.Error do
  @moduledoc """
  A classified egress failure, without destination or request values.

  `phase` is `:validate`, `:resolve`, `:connect`, `:tls`, `:send`, `:head`,
  or `:body`. `sent: :none` means no HTTP bytes were written. Once a write
  is attempted, `sent` stays `:possible`, even on a transport failure.
  `status` is the final HTTP status when available.

  The closed reason set is `:destination_mismatch`, `:unsafe_destination`,
  `:unresolved_host`, `:connect_failed`, `:tls_failed`,
  `:certificate_pin_mismatch`, `:cert_ip_mismatch`, `:invalid_certificate_pin`,
  `:certificate_pin_requires_https`, `:unsupported_method`,
  `:invalid_request`, `:invalid_options`, `:invalid_header_name`,
  `:invalid_header_value`, `:duplicate_header`, `:truncated_response`,
  `:truncated_body`, `:header_block_too_large`, `:malformed_status_line`,
  `:malformed_content_length`, `:malformed_chunked`,
  `:too_many_interim_responses`, `:body_too_large`, `:idle_timeout`,
  `:deadline_exceeded`, `:callback_failed`, `:redirect_refused`,
  `:retry_not_disabled`, `:repeat_attempt_refused`, `:unsupported_upgrade`,
  and `:transport_failed`.

  Neither the exception message nor its Inspect representation includes values.
  Inspect the fields explicitly to classify the outcome. A killed process or
  lost node returns no outcome; recover from the host's committed intent.
  """

  defexception [:reason, :phase, :sent, :status]

  @type t :: %__MODULE__{
          reason: atom(),
          phase: :validate | :resolve | :connect | :tls | :send | :head | :body,
          sent: :none | :possible,
          status: integer() | nil
        }

  @doc "Returns a fixed message containing no request or destination values."
  @impl true
  def message(_error), do: "egress request failed"
end

defimpl Inspect, for: AshHooks.Egress.Error do
  def inspect(_error, _opts), do: "#AshHooks.Egress.Error<>"
end
