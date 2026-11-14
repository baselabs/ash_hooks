defmodule AshHooks.DestinationPolicy do
  @moduledoc """
  Lets an application allow or reject a destination URL before the package
  checks whether its network address is safe. SSRF means server-side request
  forgery: requests that trick a server into reaching unintended addresses.

      defmodule MyApp.WebhookDestinations do
        @behaviour AshHooks.DestinationPolicy

        # your own rules, evaluated AHEAD of the packaged check
        @allow_exact ["https://partner.internal.example/hook"]

        @impl true
        def check(url, _ctx) when url in @allow_exact, do: :allow
        def check("https://" <> rest, _ctx), do: :default
        def check(_denied_scheme, _ctx), do: :deny
      end

  Wire it through the worker macro (`destination_policy: {MyApp.WebhookDestinations, :check}`)
  or a direct `AshHooks.Delivery.run/2` config (`destination_policy: {m, f}`
  or a 2-arity fn). The callback returns one of three decisions:

    * `:allow`; the send proceeds; the driver's packaged SSRF gate is
      skipped for this URL. The HTTP adapter's own resolve-and-pin remains
      the transport's boundary: an allow for a destination that adapter
      check would refuse (a loopback forwarder, a private network) needs
      the adapter's explicit validation override for that delivery too.
    * `:deny`; terminal: the row dead-letters under `destination_denied`
      without a send.
    * `:default`; the packaged check runs unchanged
      (`AshHooks.Ssrf.resolve_public/1`: validated-unsafe dead-letters,
      unresolvable retries under its honest label).

  The callback receives the endpoint's URL and a context map with
  `:endpoint_id` and `:tenant` (nil when the run carries none). A callback
  that raises, exits, throws, or returns a term outside the decision
  vocabulary is CONTAINED as a retryable failure
  (`destination_policy_failed`; the row climbs the backoff ladder while
  you fix the policy; a policy defect must not dead-letter deliveries).

  When no policy is configured, the packaged check runs exactly as before
  (the boolean `:ssrf_check` config keeps its behavior; a configured
  `:destination_policy` takes precedence over it).
  """

  @typedoc "The policy context: identifiers only, never endpoint fields or secrets."
  @type context :: %{required(:endpoint_id) => term(), required(:tenant) => term()}

  @typedoc "The policy decision: `:allow` bypasses the packaged gate, `:deny` is terminal, `:default` runs it."
  @type decision :: :allow | :deny | :default

  @doc """
  Decides whether the packaged send-time SSRF gate admits `url`. See the
  module documentation for the decision vocabulary and containment.
  """
  @callback check(url :: String.t(), context()) :: decision()
end
