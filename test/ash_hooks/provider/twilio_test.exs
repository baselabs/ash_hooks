defmodule AshHooks.Provider.TwilioTest do
  use ExUnit.Case, async: true

  alias AshHooks.Provider.Twilio

  # Twilio's own Python SDK vectors, including repeated form values:
  # https://github.com/twilio/twilio-python/blob/main/tests/unit/test_request_validator.py
  @uri "https://mycompany.com/myapp.php?foo=1&bar=2"
  @body "CallSid=CA1234567890ABCDE&Digits=1234&From=%2B14158675309&To=%2B18005551212&Caller=%2B14158675309"
  @signature "RSOYDt4T1cUTdK1PDd93/VVr8B8="

  test "Twilio's published form vector binds the complete URL and every parameter" do
    ctx = %{signature: @signature, request_uri: @uri}
    assert :ok = Twilio.verify_signature(@body, ctx, "12345")

    assert {:error, :invalid_signature} =
             Twilio.verify_signature(@body <> "&NewField=x", ctx, "12345")

    assert {:error, :invalid_signature} =
             Twilio.verify_signature(@body, %{ctx | request_uri: @uri <> "&x=1"}, "12345")
  end

  test "Twilio's duplicate vector sorts unique values under each sorted parameter name" do
    body = "Sid=CA123&SidAccount=AC123&Digits=5678&Digits=1234&Digits=1234"

    assert :ok =
             Twilio.verify_signature(
               body,
               %{signature: "IK+Dwps556ElfBT0I3Rgjkr1wJU=", request_uri: @uri},
               "12345"
             )
  end

  test "Twilio's published JSON vector binds bodySHA256 without adding JSON properties" do
    body = ~s({"property": "value", "boolean": true})
    uri = @uri <> "&bodySHA256=0a1ff7634d9ab3b95db5c9a2dfe9416e41502b283a80c7cf19632632f96e6620"
    ctx = %{signature: "a9nBmqA0ju/hNViExpshrM61xv4=", request_uri: uri}
    assert :ok = Twilio.verify_signature(body, ctx, "12345")
    assert {:error, :invalid_signature} = Twilio.verify_signature(body <> " ", ctx, "12345")
    assert {:ok, %{"property" => "value", "boolean" => true}} = Twilio.decode_payload(body)
  end

  test "ambiguous body hashes fail even under a valid URL MAC" do
    hash = "0a1ff7634d9ab3b95db5c9a2dfe9416e41502b283a80c7cf19632632f96e6620"
    uri = @uri <> "&bodySHA256=" <> hash <> "&bodySHA256=" <> hash
    signature = :crypto.mac(:hmac, :sha, "12345", uri) |> Base.encode64()

    assert {:error, :invalid_signature} =
             Twilio.verify_signature(
               ~s({"property": "value", "boolean": true}),
               %{signature: signature, request_uri: uri},
               "12345"
             )
  end

  test "a malformed public URL is rejected even with a matching URL MAC" do
    for uri <- ["http://[broken", "https://host:bad", "https://[]"] do
      signature = :crypto.mac(:hmac, :sha, "12345", uri) |> Base.encode64()

      assert {:error, :invalid_signature} =
               Twilio.verify_signature("", %{signature: signature, request_uri: uri}, "12345")
    end
  end

  test "missing signatures, URL, and keys fail closed; form decoding stays flat" do
    assert {:error, :no_webhook_secret} = Twilio.verify_signature(@body, %{}, "")

    for ctx <- [
          %{},
          %{signature: nil},
          %{signature: @signature},
          %{signature: @signature, request_uri: <<255>>}
        ] do
      assert {:error, :invalid_signature} = Twilio.verify_signature(@body, ctx, "12345")
    end

    assert {:ok, %{"Body" => "hello+world", "items[]" => "x"}} =
             Twilio.decode_payload("Body=hello%2Bworld&items%5B%5D=x")
  end
end
