# Verify any sender

ash_hooks verifies inbound webhooks from any sender. You describe the sender's
signature scheme in one small provider module, and the package does the
cryptography: constant-time comparison, replay windows, key rotation, and
fail-closed handling of every malformed input.

There are no built-in vendor verifiers. A sender's documentation is the
authority on its scheme, and a sender can change its scheme without waiting for
a new ash_hooks release. The recipes below show how to configure common scheme
shapes. The recipes demonstrate application-defined signature shapes. Use the
sender's documentation to configure its actual contract.

## The shape of a provider

A provider is a module that implements `AshHooks.Provider`. For most senders,
configuration is enough:

<!-- tested: verify-orders-provider -->
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

Declare this module as the required `provider` on the `:orders` inbound source.
The complete ledger and secret-source declaration is in the
[get-started application](get-started.md#declare-the-resources).

The inbound name (`:orders`) is the source's identity in the ledger. It is not a
module name and resolves nothing by convention: `provider` is required.

### Receive with the plug

Forward HTTP webhook routes to `AshHooks.Plug`, with `resource:` and either a
fixed `source:` or a stored-endpoint `resolve:` MFA. Configure `AshHooks.BodyReader`
on any preceding `Plug.Parsers`. The plug supplies exact raw bytes, ordered
request headers and the method. Set `request_uri:` to a configured public base
URL or an MFA returning the full public URI when the signature covers it. See
the [get-started tutorial](get-started.md) for routing and tenant resolution.

A hand-written provider whose `verify_signature/3` reads `ctx.signature` keeps the
default `:header` signature source. Tell the plug which header carries it:

<!-- tested: verify-any-sender-signature-header -->
```elixir
forward "/webhooks/billing", AshHooks.Plug,
  resource: MyApp.WebhookLedger,
  source: :billing,
  signature_header: "x-billing-signature"
```

A resolver may instead return `:signature_header` with the source. Exactly one
line of that header must be present; none or several are refused as unsigned.

### Lower-level request context

Configured providers read their signature and timestamp from the request
headers, so a direct `Ingress.ingest/4` caller passes the headers, the exact raw
body, and, when the scheme signs them, the method and the public request URL:

Call `AshHooks.Ingress.ingest/4` with the ledger resource, inbound source name,
exact raw body, and a context containing `headers: conn.req_headers`, `method: conn.method`,
and the configured public `request_uri`. Include the scope and tenant for resources
that require them. The [get-started application](get-started.md#verify-and-handle-an-incoming-event)
executes direct ingestion against its database.

Pass `conn.req_headers` as it is: an ordered list that keeps every header line.
Providers receive it twice. `ctx.headers` is a map in which repeated header
lines are joined with `", "`. Use `ctx.header_list` when the signing contract
needs individual header lines;
`ctx.header_list` keeps each line separately, in arrival order. A map you build
yourself is passed through unchanged, but it has already lost repeated lines.
Configured header names are matched without regard to case.

`request_uri` must be the URL the sender signed. Behind a TLS-terminating proxy,
`conn` carries the internal scheme, host, and port, so build the public URL from
a base URL you configure:

<!-- tested: verify-public-url-in-application -->
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
response. Return 5xx for missing secrets, paused sources, and retryable handler
failures. Acknowledge terminal permanent failures with 200 and expose them to
operators.

## Recipes

Each `use AshHooks.Provider` fragment below belongs inside a provider module.
These fragments are compiled inside complete provider modules and exercised in
a real application. Complete module blocks can be placed in their own files.

### HMAC of the body in a header

The most common shape: an HMAC over the exact raw body, hex or base64 encoded,
in one header.

<!-- tested: verify-shop-provider -->
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

This example verifies a base64-encoded HMAC-SHA256 of the exact request body.

### A signature header with a fixed prefix

Some senders put the algorithm name in front of the signature.

<!-- tested: verify-prefixed-provider-in-application -->
```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature: {:header, "x-hook-signature", prefix: "sha256="},
    encoding: :hex
  ]
```

This example expects `sha256=` before a lowercase hexadecimal signature.
The prefix is matched without regard to ASCII case and is not part of the
signature.

### A secret delivered as hex or base64

When the sender's documentation says to decode the secret before using it as
the HMAC key, set `key_encoding`.

<!-- tested: verify-encoded-key-provider-in-application -->
```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature: {:header, "x-encoded-key-signature"},
    encoding: :hex,
    key_encoding: :hex
  ]
```

This example decodes a hexadecimal secret before computing the HMAC.

### A timestamp and signatures in one header

A structured header carries `key=value` pairs: a timestamp and one or more
signatures. Any listed signature that verifies is accepted, which lets the sender
rotate keys.

<!-- tested: verify-structured-provider-in-application -->
```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :hmac_sha256,
    signature: {:structured_header, "x-payments-signature", signature_key: "v1"},
    timestamp: {:signature_field, "t"},
    signed_input: [:timestamp, ".", :body],
    tolerance_seconds: 300
  ]
```

This example uses the secret unchanged and signs `timestamp.body`. It accepts
any valid `v1` signature in the structured header.

### Standard Webhooks

[Standard Webhooks](https://www.standardwebhooks.com) senders sign
`id.timestamp.body` and send a space-separated list of `v1,<base64>` signatures.

<!-- tested: verify-standard-provider-in-application -->
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

ash_hooks signs its outbound webhooks using Standard Webhooks. Configure
inbound key decoding according to the sender's documented key format.

### Method, URL, body, and timestamp

Some senders sign the request line as well as the body. The signed parts are
listed in order:

<!-- tested: verify-request-provider-in-application -->
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

Some application-defined schemes transform selected URL escapes before signing.
Implement that transformation in a trusted `signed_input` function:

<!-- tested: verify-crm-provider -->
```elixir
defmodule MyApp.Webhooks.Crm do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-request-signature"},
      encoding: :base64,
      timestamp: {:header, "x-request-timestamp"},
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
         timestamp when is_binary(timestamp) <- Signature.header(ctx, "x-request-timestamp") do
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

This application-defined example uses HMAC-SHA1 over the public URL and sorted
form fields. Its JSON variant verifies a body digest before signing the URL.

<!-- tested: verify-form-provider -->
```elixir
defmodule MyApp.Webhooks.Voice do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha1,
      signature: {:header, "x-form-signature"},
      encoding: :base64,
      signed_input: {__MODULE__, :signed_input}
    ]

  alias AshHooks.Provider.Signature

  def signed_input(raw_body, %{request_uri: url}) when is_binary(url) do
    query = URI.parse(url).query || ""

    case for {"body_digest", hash} <- URI.query_decoder(query), do: hash do
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

This example authenticates selected payload fields and derives its delivery
identity from the authenticated event ID.

<!-- tested: verify-fields-provider -->
```elixir
defmodule MyApp.Webhooks.Store do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-fields-signature"},
      encoding: :base64,
      signed_input: {__MODULE__, :signed_input}
    ]

  def signed_input(raw_body, _ctx) do
    with {:ok, %{"created_at" => created, "event_id" => id}} <- Jason.decode(raw_body),
         true <- is_integer(created) and created >= 0,
         {:ok, id} <- event_id(id) do
      Integer.to_string(created) <> "." <> id
    end
  end

  # Deduplicate on the signed id: unsigned fields must not mint a new identity.
  @impl true
  def event_identity(%{"event_id" => id}), do: event_id(id)
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
PEM. This example verifies an RSA PKCS#1 v1.5 signature with SHA-256 over the
base64-encoded request body:

<!-- tested: verify-rsa-provider-in-application -->
```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :rsa_pkcs1_sha256,
    signature: {:header, "x-rsa-signature"},
    encoding: :base64,
    signed_input: [{:base64, :body}]
  ]
```

RSA-PSS, ECDSA, and Ed25519 work the same way with their `algorithm` values.
ECDSA signatures are DER by default; set `ecdsa_format: :raw` for the
fixed-width `r || s` form.

### A JWS or JWT as the body

Some senders deliver a compact JWS, often a JWT (JSON Web Token), as the whole
body. Your configuration selects the algorithm. Verification rejects a token whose
protected `alg` header does not match. A token whose header names a different algorithm, `none`, a critical
extension, or an unencoded payload is rejected. So is a token with padded
segments. When the payload is a JSON object with `exp` or `nbf` claims, they are
enforced.

<!-- tested: verify-jws-provider-in-application -->
```elixir
use AshHooks.Provider,
  verify: [
    algorithm: :rsa_pkcs1_sha256,
    signature: :jws_body
  ]
```

The generated `decode_payload/1` stores the verified JWS payload in the ledger,
and ingress needs no signature header. The generated `event_identity/1`
deduplicates on the SHA-256 of the verified payload encoded as canonical JSON
with object keys sorted and array order preserved (`AshHooks.Provider.Scheme.payload_identity/1`),
so the same signed content counts once even if it arrives with a differently
encoded signature. The example pins RS256 and loads a PEM-encoded RSA public key
from the secret source.

The ledger's `inbound_delivery.json_decoder` sets the JSON policy for each
request. It is an MFA called with the JSON bytes followed by its configured
arguments, returning `{:ok, map_or_list}` or `{:error, reason}`; the default
is `{Jason, :decode, []}`. The same function decodes the protected header,
claims, and delivered payload. Claims and delivery decode the same payload
bytes without caching a value between callbacks. A payload the decoder refuses
is a malformed payload; a protected header it refuses is an invalid signature,
as are invalid `exp` or `nbf` types.

A host-written verifier receives this function as `ctx.json_decoder`.
Generated payload decoders use it even when verification is overridden.
Direct calls to the generated `decode_payload/1` use `Jason.decode/1`.
Providers overriding that decoder must add `decode_payload/2` before a ledger
configures `json_decoder`, and decode JSON only through the supplied function.
Use `AshHooks.Provider.Conformance` in provider tests to enforce that contract.
See the tested migration example in `UPGRADING.md`.

### A timestamp in another format

When the timestamp is not Unix seconds or milliseconds, read it with a host
function that returns `{:ok, unix_seconds}` or `:error`. This example also
signs a header value and the request path:

<!-- tested: verify-date-provider -->
```elixir
defmodule MyApp.Webhooks.Parcels do
  use AshHooks.Provider,
    verify: [
      algorithm: :hmac_sha256,
      signature: {:header, "x-dated-signature", prefix: "sha256="},
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

This example parses an RFC 2822 timestamp and signs the timestamp header,
method, path, and body.
A signed path must come from your own routing (`request_uri`), never from a
header the sender controls.

### Two schemes on one route

Override `verify_signature/3` and call `AshHooks.Provider.Scheme.verify/4` when
a route must choose between schemes, for example while a sender migrates from
one version to the next:

<!-- tested: verify-migrating-provider -->
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

Use [RequestSeal](https://hex.pm/packages/request_seal) with
`{:request_seal, "~> 1.0"}` for HTTP Message Signatures (RFC 9421). Its
`RequestSeal.AshHooks` adapter integrates verification into a provider.
Follow its [webhooks guide](https://hexdocs.pm/request_seal/ash-hooks.html) for
the policy and key resolver.

Pass the exact public request URL and `conn.req_headers` to ingress so the adapter
can reconstruct covered components and individual header lines. Configure body
integrity checks and required signed components in the policy. The ash_hooks
ledger deduplicates deliveries; configure a RequestSeal replay store when each
signature nonce must be accepted only once. A policy with `replay: :not_required`
relies on the ledger for delivery deduplication and does not provide nonce reuse
protection.

## Key rotation

Rotate a shared secret or a public key without dropping deliveries:

- On an inbound declaration, add `previous_secret` with the outgoing key's
  source. Both keys verify until you remove it.
- Structured headers can carry several signatures; any one that verifies is
  accepted.
- `AshHooks.Provider.Scheme.verify/4` and the `AshHooks.Provider.Signature`
  functions accept a list of keys.

Add `previous_secret` beside `secret` in the inbound declaration, using the
same resolver shapes for the outgoing key. Both values can use tenant-aware
sources. Remove the previous source when the overlap period ends.

## Classifying events and running your actions

Configured providers classify every verified request as `:webhook` and keep the
sender's event names in the payload. Override `parse_event_type/1` and
`handle_event/2` to map event names to your own atoms and run idempotent
application actions. This example returns the classified event; the
[get-started application](get-started.md#declare-the-resources) shows a database update:

<!-- tested: verify-classification-provider -->
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
  def handle_event(:order_paid, payload), do: {:ok, %AshHooks.Provider.Event{type: :order_paid, payload: payload}}
  def handle_event(:order_refunded, payload), do: {:ok, %AshHooks.Provider.Event{type: :order_refunded, payload: payload}}
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

<!-- tested: verify-custom-provider -->
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

<!-- tested: verify-provider-test-in-application -->
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
