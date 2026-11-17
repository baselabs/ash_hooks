defmodule AshHooks.ErrorsTest do
  use ExUnit.Case, async: true

  alias AshHooks.Errors

  alias AshHooks.Errors.Invalid.{
    InvalidSignature,
    MalformedPayload,
    NoWebhookSecret,
    StaleTimestamp,
    UnknownEventType
  }

  test "unwrap! returns successes and raises the converted error for every refusal shape" do
    assert Errors.unwrap!({:ok, 42}, []) == 42
    assert Errors.unwrap!(:ok, []) == :ok
    error = InvalidSignature.exception(provider: :sender)
    assert_raise InvalidSignature, fn -> Errors.unwrap!({:error, error}, []) end
    assert_raise Errors.Unknown, fn -> Errors.unwrap!(:error, []) end
    assert_raise ArgumentError, fn -> Errors.unwrap!({:unexpected, 42}, []) end
  end

  test "traverse_errors visits nested leaves and groups results by their paths" do
    signature = Errors.set_path(InvalidSignature.exception(provider: :sender), [:signature])
    payload = Errors.set_path(MalformedPayload.exception(provider: :sender), [:payload])
    errors = Errors.to_class([signature, payload])

    assert %{signature: [:invalid_signature], payload: [:malformed_payload]} =
             Errors.traverse_errors(errors, fn
               %InvalidSignature{} -> :invalid_signature
               %MalformedPayload{} -> :malformed_payload
             end)

    assert %{signature: [InvalidSignature]} = Errors.traverse_errors([signature], & &1.__struct__)
  end

  describe "from_reason/2" do
    test "preserves every classified package error" do
      for module <- [
            InvalidSignature,
            MalformedPayload,
            NoWebhookSecret,
            StaleTimestamp,
            UnknownEventType,
            Errors.Invalid.UnknownSource,
            Errors.Invalid.UnknownKey,
            Errors.Invalid.KeyKindMismatch,
            Errors.Unknown.KeyUnavailable,
            Errors.Unknown.UnknownError
          ] do
        error = module.exception([])
        assert Errors.from_reason(error, provider: :other) === error
      end
    end

    test "maps every provider reason atom to its error def" do
      assert %InvalidSignature{provider: :mock} =
               Errors.from_reason(:invalid_signature, provider: :mock)

      assert %NoWebhookSecret{provider: :mock} =
               Errors.from_reason(:no_webhook_secret, provider: :mock)

      assert %StaleTimestamp{provider: :mock} =
               Errors.from_reason(:stale_timestamp, provider: :mock)

      assert %UnknownEventType{provider: :mock, event_type: "nope"} =
               Errors.from_reason(:unknown_event_type, provider: :mock, event_type: "nope")

      assert %MalformedPayload{provider: :mock} =
               Errors.from_reason(:malformed_payload, provider: :mock)
    end

    test "unmapped reasons become a contents-free unknown error" do
      assert %Errors.Unknown.UnknownError{} = error = Errors.from_reason(:not_a_reason, [])
      refute inspect(error) =~ "not_a_reason"
    end
  end

  describe "error defs" do
    test "are splode errors with rendered messages and the invalid class" do
      for mod <-
            [
              InvalidSignature,
              NoWebhookSecret,
              StaleTimestamp,
              UnknownEventType,
              MalformedPayload
            ] do
        error = mod.exception(provider: :mock)

        assert Errors.splode_error?(error), "#{inspect(mod)} is not a splode error"
        assert error.class == :invalid
        assert is_binary(mod.message(error)) and mod.message(error) != ""
      end
    end

    test "messages name the provider and the specifics the fields carry" do
      assert InvalidSignature.message(%InvalidSignature{
               provider: :mock
             }) =~
               "mock"

      assert UnknownEventType.message(%UnknownEventType{
               provider: :mock,
               event_type: "nope"
             }) =~ "nope"
    end
  end

  describe "splode integration" do
    test "to_error_class aggregates into the invalid class module" do
      error = InvalidSignature.exception(provider: :mock)

      assert %Errors.Invalid{} = class = Errors.to_class([error])
      # to_class stamps the error's :splode field on the way in, so assert on
      # the aggregated shape rather than identity with the pre-class error.
      assert [%InvalidSignature{provider: :mock}] = class.errors
    end

    test "unknown values fall through to the unknown error" do
      assert %Errors.Unknown.UnknownError{} = Errors.to_error(:boom)
    end
  end
end
