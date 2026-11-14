defmodule AshHooks.CustodyErrorsTest do
  use ExUnit.Case, async: true

  alias AshHooks.Errors
  alias AshHooks.Errors.Invalid.{InvalidSignature, KeyKindMismatch, UnknownKey, UnknownSource}
  alias AshHooks.Errors.Unknown.{KeyUnavailable, UnknownError}

  test "each new error has its fixed reason, class, and contents-free message" do
    for {reason, module, class} <- [
          {:unknown_source, UnknownSource, :invalid},
          {:key_kind_mismatch, KeyKindMismatch, :invalid},
          {:unknown_key, UnknownKey, :invalid},
          {:key_unavailable, KeyUnavailable, :unknown}
        ] do
      error = Errors.from_reason(reason, [])
      assert error.__struct__ == module
      assert error.class == class
      assert Errors.splode_error?(error)
      assert Exception.message(error) != ""
      assert AshHooks.Telemetry.classify_token(reason) == Atom.to_string(reason)
    end
  end

  test "every custody-result row maps to its specified class or fixed issuing result" do
    assert :ok = Errors.from_custody_result(:ok)
    assert {:ok, <<1, 2>>} = Errors.from_custody_result({:ok, <<1, 2>>})

    for {reason, module} <- [
          {:invalid_signature, InvalidSignature},
          {:unavailable, KeyUnavailable},
          {:unknown_ref, UnknownKey},
          {:kind_mismatch, KeyKindMismatch},
          {:not_signable, KeyKindMismatch},
          {:no_public_half, KeyKindMismatch},
          {:ref_exists, UnknownError}
        ] do
      assert {:error, error} = Errors.from_custody_result({:error, reason})
      assert error.__struct__ == module
    end

    for reason <- [:no_fingerprint, :invalid_material, :tenant_mismatch] do
      assert {:error, ^reason} = Errors.from_custody_result({:error, reason})
    end

    assert {:error, :key_issue_expired} = Errors.from_custody_result({:error, :ref_destroyed})
  end

  test "unrecognized custody and reason terms never escape in returned errors" do
    backend = {:backend_failure, "private backend details"}

    for result <- [{:error, backend}, backend, {:error, :unexpected}] do
      assert {:error, error} = Errors.from_custody_result(result)
      assert error.__struct__ == UnknownError
      refute inspect(error) =~ "private backend details"
      refute Exception.message(error) =~ "private backend details"
    end

    error = Errors.from_reason(backend, error: backend)
    assert error.__struct__ == UnknownError
    refute inspect(error) =~ "private backend details"
  end
end
