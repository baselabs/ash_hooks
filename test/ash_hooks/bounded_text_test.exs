defmodule AshHooks.BoundedTextTest do
  @moduledoc false
  use ExUnit.Case, async: true

  # cap/2 is the package's unit-proof bound: n bytes implies at most n
  # codepoints and at most n graphemes, so a capped value satisfies a
  # same-n max_length constraint in every counting mode (Ash 3.33
  # :codepoints vs :mixed) — a grapheme-counted slice cannot promise that.

  test "input at or under the cap passes through unchanged" do
    assert AshHooks.BoundedText.cap("short", 255) == "short"
    assert AshHooks.BoundedText.cap("", 255) == ""
    assert AshHooks.BoundedText.cap(String.duplicate("a", 255), 255) == String.duplicate("a", 255)
  end

  test "a cut landing inside a multi-byte sequence repairs the boundary" do
    input = String.duplicate("🎉", 100)
    capped = AshHooks.BoundedText.cap(input, 10)

    assert byte_size(capped) <= 10
    assert String.valid?(capped)
    assert String.starts_with?(input, capped)
  end

  test "combining characters are bounded by bytes, not graphemes" do
    # 3000 graphemes at 2 codepoints each: a grapheme-counted cap of 2048
    # would pass 4096 codepoints through to a codepoint-counted constraint
    input = String.duplicate("à́", 3000)
    capped = AshHooks.BoundedText.cap(input, 2048)

    assert byte_size(capped) <= 2048
    assert capped |> String.to_charlist() |> length() <= 2048
    assert String.valid?(capped)
  end

  test "input invalid past the boundary falls through unrepaired (cap bounds size, not validity)" do
    capped = AshHooks.BoundedText.cap(String.duplicate(<<0xFF>>, 100), 50)

    # the 3-byte repair budget drops and gives up: still invalid, still bounded
    assert byte_size(capped) == 47
    refute String.valid?(capped)
  end

  # Documented (delta review note): input invalid BEFORE the cut can burn
  # the repair budget on already-invalid bytes, dropping valid bytes the
  # cut never touched. No caller hits this today — every caller either
  # validates first (redact, error_class_string) or feeds classify_token
  # output (ASCII or "unclassified"). This test pins the contract.
  test "input invalid before the cut stays bounded but is not repaired" do
    capped = AshHooks.BoundedText.cap(<<0xFF, 0xFF>> <> "abc", 4)

    assert byte_size(capped) <= 4
    refute String.valid?(capped)
  end
end
