# Verify any sender

ash_hooks verifies inbound webhooks from any sender. You describe the sender's
signature scheme in one small provider module, and the package does the
cryptography: constant-time comparison, replay windows, key rotation, and
fail-closed handling of every malformed input.

There are no built-in vendor verifiers. A sender's documentation is the
authority on its scheme, and a sender can change its scheme without waiting for
a new ash_hooks release. The recipes below show how to configure common scheme
shapes. Where a recipe names a vendor, it is an example of that shape, with a
link to the vendor's own documentation. The vendor's documentation is
authoritative, and a recipe is not a maintained integration: check the current
contract before you rely on it.

## The shape of a provider

A provider is a module that implements `AshHooks.Provider`. For most senders,
configuration is enough:

```elixir
defmodule MyApp.Webhooks.Orders do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-orders-signature"},
      encoding: :hex
    ]
end
```

`use AshHooks.Provider, verify: [...]` checks the options when your module
compiles and generates these callbacks:

- `verify_signature/3`, which verifies with the configured scheme;
- `timestamp_header/0` and `signature_source/0`, which tell ingress where the
  timestamp and signature live;
- `parse_event_type/1` and `handle_event/2`, which classify every verified
  request as `:webhook` and return an `AshHooks.Provider.Event`;
- `decode_payload/1` and `event_identity/1`, for senders that sign a JWS (JSON
  Web Signature) body.

Every generated callback can be overridden. Point an inbound declaration at the
module:

```elixir
webhooks do
  inbound :orders do
    provider MyApp.Webhooks.Orders
    secret {:app_env, [:my_app, :orders_webhook_secret]}
  end
end
```

The inbound name (`:orders`) is the source's identity in the ledger. It is not a
module name and resolves nothing by convention: `provider` is required.

### What your controller passes

Configured providers read their signature and timestamp from the request
headers, so pass the headers, the exact raw body, and, when the scheme signs
them, the method and the public request URL:

```elixir
raw_body = conn.private[:ash_hooks_raw_body]

AshHooks.Ingress.ingest(MyApp.WebhookLedger, :orders, raw_body, %{
  headers: conn.req_headers,
  method: conn.method,
  request_uri: MyApp.Webhooks.public_url(conn)
})
```

Pass `conn.req_headers` as it is: an ordered list that keeps every header line.
Providers receive it twice. `ctx.headers` is a map in which repeated header
lines are joined with `", "`, the HTTP rule for repeated fields, and
`ctx.header_list` keeps each line separately, in arrival order. A map you build
yourself is passed through unchanged, but it has already lost repeated lines.
Configured header names are matched without regard to case.

`request_uri` must be the URL the sender signed. Behind a TLS-terminating proxy,
`conn` carries the internal scheme, host, and port, so build the public URL from
a base URL you configure:

```elixir
def public_url(conn) do
  base = Application.fetch_env!(:my_app, :public_webhook_base_url)
  query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
  base <> conn.request_path <> query
end
```

Never derive the public URL from a forwarded header the sender or an
intermediary controls.

## Configuration reference

The full option reference lives in `AshHooks.Provider.Scheme`. In short:

| Option | Values | Default |
| --- | --- | --- |
| `algorithm` | `:hmac_sha1`, `:hmac_sha256`, `:hmac_sha384`, `:hmac_sha512`, `:rsa_pkcs1_sha256`, `:rsa_pkcs1_sha384`, `:rsa_pkcs1_sha512`, `:rsa_pss_sha256`, `:rsa_pss_sha384`, `:rsa_pss_sha512`, `:ecdsa_p256_sha256`, `:ecdsa_p384_sha384`, `:ed25519` | required |
| `signature` | `{:header, name}`, `{:header, name, prefix: "..."}`, `{:structured_header, name, signature_key: "...", pair_separator: ",", key_value_separator: "="}`, `:jws_body` | required |
| `encoding` | `:hex` (lowercase), `:hex_upper`, `:hex_any`, `:base64`, `:base64url` | `:hex` for HMAC, `:base64` for public keys |
| `ecdsa_format` | `:der`, `:raw` (fixed-width `r \|\| s`) | `:der` |
| `key_encoding` | `:raw`, `:hex`, `:base64`, `:base64url` | `:raw` |
| `key_prefix` | a literal prefix to strip from the secret, such as `"whsec_"` | none |
| `signed_input` | `:body`, a list of parts, `{module, function}`, or a 2-arity function | `:body` |
| `timestamp` | `{:header, name}`, `{:signature_field, key}`, `{module, function}`, or a 2-arity function | none |
| `timestamp_unit` | `:seconds`, `:milliseconds` | `:seconds` |
| `tolerance_seconds` | positive integer, symmetric about the clock | `300` |

Signed-input parts are concatenated with no separator. A part is a literal
binary, `:body` (the exact raw bytes), `:timestamp` (the timestamp text exactly as
received), `:method`, `:url` (the `request_uri` you passed, unchanged), `:path`
(its path component, without the query, not decoded), `{:header, name}`, or
`{:base64, part}`. A missing header, method, or URL makes verification fail;
it never substitutes an empty value.

Options are part of your code. Never build them from the request.

### Keys

The inbound `secret` source supplies the key. For HMAC (hash-based message
authentication code) it is the shared secret, decoded according to
`key_encoding` after `key_prefix` is removed. For RSA, ECDSA (elliptic curve
digital signature algorithm), and Ed25519 it is the sender's public key,
PEM-encoded: a `PUBLIC KEY`, an
`RSA PUBLIC KEY`, or a `CERTIFICATE`. A certificate is used only as a container
for the key you pinned; ash_hooks does not check its chain, expiry, or
revocation. An Ed25519 key can also be its 32 raw bytes, decoded with
`key_encoding`.

Keys come only from your configuration. ash_hooks never fetches a key from a URL,
a header, or the token being verified.

### Timestamps and replay

When `timestamp` is set, a request verifies only if the signature is valid and
the timestamp is within `tolerance_seconds` of the clock, in either direction.
The signature is always checked first: a fresh timestamp never makes an invalid
signature acceptable, and a request with an invalid signature reports
`:invalid_signature` even when its timestamp is also stale.

A `replay_window_seconds` on the inbound declaration overrides the tolerance.
It needs a timestamp that ingress can name, so it works with `{:header, name}`
and `{:signature_field, key}` timestamps and is rejected at compile time for a
scheme without one. A timestamp read by a host function still uses
`tolerance_seconds`.

Deduplication on the ledger is the replay defense for schemes that sign no
timestamp.

### Results

Verification returns `:ok` or one of three errors, never an exception and never
key or signature bytes:

- `{:error, :invalid_signature}`: missing, malformed, or wrong signature, or a
  part of the signed input is missing;
- `{:error, :no_webhook_secret}`: the secret source returned no usable key;
- `{:error, :stale_timestamp}`: a valid signature outside the replay window.

Ingress turns these into `AshHooks.Errors` values before it writes a delivery
row. With `ingress_tracking :on`, a rejected request records only a digest row
for `counts/2`. Answer `:invalid_signature` and `:stale_timestamp` with a 4xx
response. Answer `:no_webhook_secret`, a paused source, and handler failures with
a 5xx, so the sender retries once you fix the cause.

## Recipes

### HMAC of the body in a header

The most common shape: an HMAC over the exact raw body, hex or base64 encoded,
in one header.

```elixir
defmodule MyApp.Webhooks.Shop do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-shop-signature"},
      encoding: :base64
    ]
end
```

Examples of this shape: [Shopify](https://shopify.dev/docs/apps/build/webhooks/verify-deliveries)
(`x-shopify-hmac-sha256`, base64) and
[WooCommerce](https://developer.woocommerce.com/docs/apis/rest-api/v1/webhooks/)
(`x-wc-webhook-signature`, base64, its default algorithm).

### A signature header with a fixed prefix

Some senders put the algorithm name in front of the signature.

```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature: {:header, "x-hub-signature-256", prefix: "sha256="},
    encoding: :hex
  ]
```

Example: [GitHub](https://docs.github.com/en/webhooks/using-webhooks/validating-webhook-deliveries).
The prefix is matched without regard to ASCII case and is not part of the
signature.

### A secret delivered as hex or base64

When the sender's documentation says to decode the secret before using it as
the HMAC key, set `key_encoding`.

```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature: {:header, "squarespace-signature"},
    encoding: :hex,
    key_encoding: :hex
  ]
```

Example: [Squarespace](https://commerce-apis.squarespace.com/webhooks/verifying-notifications),
whose subscription secret is hexadecimal.

### A timestamp and signatures in one header

A structured header carries `key=value` pairs: a timestamp and one or more
signatures. Any listed signature that verifies is accepted, which lets the sender
rotate keys.

```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature: {:structured_header, "stripe-signature", signature_key: "v1"},
    timestamp: {:signature_field, "t"},
    signed_input: [:timestamp, ".", :body],
    tolerance_seconds: 300
  ]
```

Examples: [Stripe](https://docs.stripe.com/webhooks/signature) (`t=...,v1=...`;
its `whsec_...` secret is used as the key exactly as issued, so set no
`key_prefix`) and [Shippo](https://docs.goshippo.com/tracking/webhook-security)
(`shippo-auth-signature`, same shape).

### Standard Webhooks

[Standard Webhooks](https://www.standardwebhooks.com) senders sign
`id.timestamp.body` and send a space-separated list of `v1,<base64>` signatures.

```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature:
      {:structured_header, "webhook-signature",
       signature_key: "v1", pair_separator: " ", key_value_separator: ","},
    encoding: :base64,
    key_prefix: "whsec_",
    key_encoding: :base64,
    timestamp: {:header, "webhook-timestamp"},
    signed_input: [{:header, "webhook-id"}, ".", :timestamp, ".", :body]
  ]
```

For the asymmetric `v1a` variant, use `algorithm: :ed25519`,
`signature_key: "v1a"`, and `key_prefix: "whpk_"`; the secret source returns the
sender's public key.

Example: [BigCommerce](https://docs.bigcommerce.com/developer/docs/beta/webhooks/http-webhooks#webhook-signature)
uses this shape with its raw app client secret as the key, so leave out
`key_prefix` and `key_encoding` for it. ash_hooks signs its own outbound webhooks
with this scheme (`AshHooks.Signing`).

### Method, URL, body, and timestamp

Some senders sign the request line as well as the body. The signed parts are
listed in order:

```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature: {:header, "x-request-signature"},
    encoding: :base64,
    timestamp: {:header, "x-request-timestamp"},
    timestamp_unit: :milliseconds,
    signed_input: [:method, :url, :body, :timestamp]
  ]
```

When the sender transforms the URL before signing, use a host function for the
signed input. [HubSpot's v3 scheme](https://developers.hubspot.com/docs/apps/legacy-apps/authentication/validating-requests)
signs `method <> uri <> body <> timestamp` after decoding a fixed set of
percent-escapes in the URI:

```elixir
defmodule MyApp.Webhooks.Crm do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-hubspot-signature-v3"},
      encoding: :base64,
      timestamp: {:header, "x-hubspot-request-timestamp"},
      timestamp_unit: :milliseconds,
      signed_input: {__MODULE__, :signed_input}
    ]

  alias AshHooks.Provider.Signature

  @decoded %{
    "%3A" => ":", "%2F" => "/", "%3F" => "?", "%40" => "@", "%21" => "!", "%24" => "$",
    "%27" => "'", "%28" => "(", "%29" => ")", "%2A" => "*", "%2C" => ",", "%3B" => ";"
  }

  def signed_input(raw_body, ctx) do
    with method when is_binary(method) <- ctx[:method],
         uri when is_binary(uri) <- ctx[:request_uri],
         timestamp when is_binary(timestamp) <- Signature.header(ctx, "x-hubspot-request-timestamp") do
      method <> decode(uri) <> raw_body <> timestamp
    end
  end

  defp decode(uri) do
    Regex.replace(~r/%(?:3A|2F|3F|40|21|24|27|28|29|2A|2C|3B)/i, uri, fn escape ->
      Map.fetch!(@decoded, String.upcase(escape))
    end)
  end
end
```

A function that returns anything other than a binary, or raises, fails
verification.

### Sorted form fields

[Twilio](https://www.twilio.com/docs/usage/webhooks/webhooks-security) signs the
public URL followed by every form field name and value, sorted by name, with
HMAC-SHA1. JSON requests instead carry the body's SHA-256 in a `bodySHA256`
query parameter and sign the URL alone.

```elixir
defmodule MyApp.Webhooks.Voice do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha1,
      signature: {:header, "x-twilio-signature"},
      encoding: :base64,
      signed_input: {__MODULE__, :signed_input}
    ]

  alias AshHooks.Provider.Signature

  def signed_input(raw_body, %{request_uri: url}) when is_binary(url) do
    query = URI.parse(url).query || ""

    case for {"bodySHA256", hash} <- URI.query_decoder(query), do: hash do
      [] ->
        url <> form_suffix(raw_body)

      [hash] ->
        digest = Base.encode16(:crypto.hash(:sha256, raw_body), case: :lower)
        if Signature.compare(digest, hash) == :ok, do: url

      _ ->
        nil
    end
  end

  def signed_input(_raw_body, _ctx), do: nil

  defp form_suffix(raw_body) do
    raw_body
    |> URI.query_decoder()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, values} ->
      values |> Enum.uniq() |> Enum.sort() |> Enum.map(&[name, &1])
    end)
    |> IO.iodata_to_binary()
  end
end
```

Declare `body_format :form` on the inbound route (or implement `body_format/0`)
so the verified form body is decoded into the ledger payload.

### A signature over selected payload fields

[Ecwid](https://github.com/Ecwid/ecwid-api-docs/blob/master/includes/_webhooks.md#webhooks-security)
signs `eventCreated.eventId` from the JSON body, not the whole body:

```elixir
defmodule MyApp.Webhooks.Store do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-ecwid-webhook-signature"},
      encoding: :base64,
      signed_input: {__MODULE__, :signed_input}
    ]

  def signed_input(raw_body, _ctx) do
    with {:ok, %{"eventCreated" => created, "eventId" => id}} <- Jason.decode(raw_body),
         true <- is_integer(created) and created >= 0,
         {:ok, id} <- event_id(id) do
      Integer.to_string(created) <> "." <> id
    end
  end

  # Deduplicate on the signed id: unsigned fields must not mint a new identity.
  @impl true
  def event_identity(%{"eventId" => id}), do: event_id(id)
  def event_identity(_payload), do: {:error, :malformed_payload}

  defp event_id(id) when is_binary(id) and id != "", do: {:ok, id}
  defp event_id(id) when is_integer(id) and id >= 0, do: {:ok, Integer.to_string(id)}
  defp event_id(_id), do: {:error, :malformed_payload}
end
```

**Fields outside the signed input are not authenticated.** Treat them as hints
and fetch authoritative data from the sender's API before acting on them.

### An RSA signature header

For public-key schemes, the secret source returns the sender's public key as
PEM. [Adobe Commerce](https://developer.adobe.com/commerce/extensibility/webhooks/signature-verification)
signs the base64 encoding of the raw body with RSA and SHA-256:

```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :rsa_pkcs1_sha256,
    signature: {:header, "x-adobe-commerce-webhook-signature"},
    encoding: :base64,
    signed_input: [{:base64, :body}]
  ]
```

RSA-PSS, ECDSA, and Ed25519 work the same way with their `algorithm` values.
ECDSA signatures are DER by default; set `ecdsa_format: :raw` for the
fixed-width `r || s` form.

### A JWS or JWT as the body

Some senders deliver a compact JWS, often a JWT (JSON Web Token), as the whole
body. The algorithm is pinned by your configuration and never read from the
token. A token whose header names a different algorithm, `none`, a critical
extension, or an unencoded payload is rejected. So is a token with padded
segments. When the payload is a JSON object with `exp` or `nbf` claims, they are
enforced.

```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :rsa_pkcs1_sha256,
    signature: :jws_body
  ]
```

The generated `decode_payload/1` stores the verified JWS payload in the ledger,
and ingress needs no signature header. The generated `event_identity/1`
deduplicates on the SHA-256 of that payload (`AshHooks.Provider.Scheme.payload_identity/1`),
so the same signed content counts once even if it arrives with a differently
encoded signature. Example:
[Wix](https://dev.wix.com/docs/build-apps/develop-your-app/api-integrations/events-and-webhooks/about-webhooks),
an RS256 JWT verified with the app's public key.

### A timestamp in another format

When the timestamp is not Unix seconds or milliseconds, read it with a host
function that returns `{:ok, unix_seconds}` or `:error`. This example also
signs a header value and the request path:

```elixir
defmodule MyApp.Webhooks.Parcels do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-hmac-signature-v2", prefix: "hmac-sha256-hex="},
      encoding: :hex_any,
      signed_input: [{:header, "x-timestamp"}, :method, :path, :body],
      timestamp: {__MODULE__, :timestamp},
      tolerance_seconds: 60
    ]

  alias AshHooks.Provider.Signature

  # "Tue, 19 Aug 2025 20:37:09 -0000" (RFC 2822 with a numeric offset)
  def timestamp(_raw_body, ctx) do
    with value when is_binary(value) <- Signature.header(ctx, "x-timestamp"),
         [_, day, month, year, time, sign, hours, minutes] <-
           Regex.run(~r/\A\w{3}, (\d{1,2}) (\w{3}) (\d{4}) (\d{2}:\d{2}:\d{2}) ([+-])(\d{2})(\d{2})\z/, value),
         month when is_integer(month) <- month_number(month),
         {:ok, date} <- Date.new(String.to_integer(year), month, String.to_integer(day)),
         {:ok, time} <- Time.from_iso8601(time),
         {:ok, datetime} <- DateTime.new(date, time) do
      offset = String.to_integer(hours) * 3600 + String.to_integer(minutes) * 60
      offset = if sign == "-", do: -offset, else: offset
      {:ok, DateTime.to_unix(datetime) - offset}
    else
      _ -> :error
    end
  end

  @months ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  defp month_number(name), do: Enum.find_index(@months, &(&1 == name)) |> then(&(&1 && &1 + 1))
end
```

Example: [EasyPost's v2 HMAC](https://support.easypost.com/hc/en-us/articles/39826034964237-Webhook-HMAC-Validation).
A signed path must come from your own routing (`request_uri`), never from a
header the sender controls.

### Two schemes on one route

Override `verify_signature/3` and call `AshHooks.Provider.Scheme.verify/4` when
a route must choose between schemes, for example while a sender migrates from
one version to the next:

```elixir
defmodule MyApp.Webhooks.Migrating do
  use AshHooks.Provider
  alias AshHooks.Provider.{Event, Scheme, Signature}

  @impl true
  def verify_signature(raw_body, ctx, secret) do
    if Signature.header(ctx, "x-signature-v2"),
      do: Scheme.verify(raw_body, ctx, secret, v2()),
      else: Scheme.verify(raw_body, ctx, secret, v1())
  end

  @impl true
  def signature_source, do: :request

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build

  defp v1, do: [algorithm: :hmac_sha256, signature: {:header, "x-signature"}]

  defp v2,
    do: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-signature-v2"},
      timestamp: {:header, "x-timestamp"},
      signed_input: [:timestamp, ".", :body]
    ]
end
```

A present newer header is authoritative here: a request carrying a bad v2
signature never falls back to v1. `signature_source/0` returning `:request`
tells ingress that the provider reads its own signature from the headers.

### HTTP Message Signatures (RFC 9421) with RequestSeal

Senders that sign with [HTTP Message Signatures](https://www.rfc-editor.org/rfc/rfc9421.html)
put `signature` and `signature-input` headers on the request, naming exactly
which components they cover. Verify them with
[RequestSeal](https://hex.pm/packages/request_seal) 1.0 or later, a separate package that adds
what this scheme needs beyond a signature check: required covered components,
freshness and expiry, body integrity through content digests
([RFC 9530](https://www.rfc-editor.org/rfc/rfc9530.html)), and one-time nonces
through a replay store you supervise.

```elixir
# mix.exs
{:request_seal, "~> 1.0"}
```

Its `RequestSeal.AshHooks` adapter verifies inside a provider. The inbound
`secret` source returns a key *reference*; your policy function turns it into a
`RequestSeal.Policy`, so RequestSeal never treats the reference as key material:

```elixir
defmodule MyApp.Webhooks.Signed do
  use AshHooks.Provider
  alias AshHooks.Provider.Event

  @components ~s[("@method" "@authority" "@path" "content-digest" "content-type")]

  @impl true
  def verify_signature(raw_body, ctx, key_reference) do
    RequestSeal.AshHooks.verify_signature(raw_body, ctx, key_reference,
      policy: &policy/2,
      label: "sig"
    )
  end

  # The adapter reads the signature headers itself; ingress needs no ctx.signature.
  @impl true
  def signature_source, do: :request

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build

  # Called with the ingest tenant and the secret source's key reference.
  def policy(_tenant, key_reference) do
    {:ok, public_key} = MyApp.Keys.public_key(key_reference)

    {:ok, policy} =
      RequestSeal.Policy.new(%{
        algorithms: ["ed25519"],
        components: @components,
        key_resolver: fn _params -> {:ok, %{algorithm: "ed25519", key: public_key}} end,
        freshness: %{
          clock: fn -> System.system_time(:second) end,
          max_age: 300,
          skew: 5,
          require_expires: true
        },
        content: %{kind: :content, algorithms: ["sha-256"], section: :headers},
        replay: :not_required
      })

    policy
  end
end
```

`replay: :not_required` keeps the example short. To accept each signed request
once, configure a replay store in the policy, as RequestSeal's
[replay protection guide](https://hexdocs.pm/request_seal/replay-protection.html)
describes. ash_hooks still deduplicates deliveries on its ledger.

Pass `headers: conn.req_headers` to ingress. The adapter rebuilds the signed
request from `ctx.header_list`, so a covered header that arrives on several
lines verifies exactly as it was sent. Pass the exact URL the sender signed,
query included, as `request_uri`; ash_hooks hands it to the adapter unchanged.
A policy function that fails makes verification fail; it never accepts the
request. RequestSeal's [webhooks with ash_hooks guide](https://hexdocs.pm/request_seal/ash-hooks.html)
also covers signing your outbound ash_hooks deliveries with RFC 9421.

## Key rotation

Rotate a shared secret or a public key without dropping deliveries:

- On an inbound declaration, add `previous_secret` with the outgoing key's
  source. Both keys verify until you remove it.
- Structured headers can carry several signatures; any one that verifies is
  accepted.
- `AshHooks.Provider.Scheme.verify/4` and the `AshHooks.Provider.Signature`
  functions accept a list of keys.

```elixir
inbound :orders do
  provider MyApp.Webhooks.Orders
  secret {:app_env, [:my_app, :orders_secret]}
  previous_secret {:app_env, [:my_app, :orders_secret_previous]}
end
```

## Classifying events and running your actions

Configured providers classify every verified request as `:webhook` and keep the
sender's event names in the payload. Override `parse_event_type/1` and
`handle_event/2` to map event names to your own atoms and run idempotent
application actions:

```elixir
defmodule MyApp.Webhooks.Orders do
  use AshHooks.Provider,
    verify: [algorithm: :hmac_sha256, signature: {:header, "x-orders-signature"}]

  @types %{"order.paid" => :order_paid, "order.refunded" => :order_refunded}

  @impl true
  def parse_event_type(%{"type" => type}) do
    case Map.fetch(@types, type) do
      {:ok, atom} -> {:ok, atom}
      :error -> {:error, :unknown_event_type}
    end
  end

  def parse_event_type(_payload), do: {:error, :malformed_payload}

  @impl true
  def handle_event(:order_paid, payload), do: MyApp.Orders.mark_paid(payload)
  def handle_event(:order_refunded, payload), do: MyApp.Orders.mark_refunded(payload)
end
```

Map event names with an explicit table; never call `String.to_atom/1` on request
data. An unknown type is recorded as a permanent failure, so it does not retry
forever. Write `handle_event/2` so that running it twice for the same event is
harmless: the ledger deduplicates deliveries, but a crash after your side effect
and before the ledger update re-runs the handler on redelivery.

For a stable deduplication identity, return the sender's event id from the
declaration's `event_id` option or the provider's `event_identity/1` callback.
Without either, the SHA-256 of the raw body is the identity (for a JWS-body
provider, the SHA-256 of its verified payload).

## When configuration is not enough

Implement `verify_signature/3` yourself. The building blocks are public in
`AshHooks.Provider.Signature`:

- `hmac/4`, `rsa/4`, `ecdsa/4`, `ed25519/4`, and `jws/3` verify signatures;
- `compare/2` compares two binaries in constant time;
- `header/2` reads a request header without regard to case;
- `check_timestamp/3` applies a symmetric replay window.

```elixir
defmodule MyApp.Webhooks.Custom do
  use AshHooks.Provider
  alias AshHooks.Provider.{Event, Signature}

  @impl true
  def verify_signature(raw_body, ctx, secret) do
    with nonce when is_binary(nonce) <- Signature.header(ctx, "x-nonce"),
         signature when is_binary(signature) <- Signature.header(ctx, "x-signature") do
      Signature.hmac(nonce <> ":" <> raw_body, signature, secret, digest: :sha512)
    else
      _ -> {:error, :invalid_signature}
    end
  end

  @impl true
  def signature_source, do: :request

  @impl true
  defdelegate parse_event_type(payload), to: Event, as: :parse
  @impl true
  defdelegate handle_event(type, payload), to: Event, as: :build
end
```

Hold your own implementation to the same rules: verify the exact raw bytes,
compare in constant time, take keys and options only from your code, and return
an error tuple for every malformed input.

## Test your provider

Test with the sender's published known-answer vectors where they exist, and
with signatures you compute yourself:

```elixir
test "accepts a signed body and rejects a changed byte" do
  secret = :crypto.strong_rand_bytes(32)
  body = ~s({"type":"order.paid","id":"evt_1"})
  signature = :crypto.mac(:hmac, :sha256, secret, body) |> Base.encode16(case: :lower)
  ctx = %{headers: %{"x-orders-signature" => signature}}

  assert :ok = MyApp.Webhooks.Orders.verify_signature(body, ctx, secret)

  assert {:error, :invalid_signature} =
           MyApp.Webhooks.Orders.verify_signature(body <> " ", ctx, secret)
end
```

Direct calls accept a `:now_ms` entry in the context to pin the clock for
timestamp tests. Ingress never forwards it from a request.
