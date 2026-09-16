defmodule AshHooks.BoundedText do
  @moduledoc false

  # Grapheme-counted String.slice/3 does not bound what a max_length
  # constraint counts: since Ash 3.33, the counting mode is the HOST
  # application's choice (`config :ash, :default_string_length_count`),
  # and :codepoints counts codepoints — a single grapheme can carry
  # unboundedly many. A grapheme-sliced value written to a
  # length-constrained attribute after the fact (the post-send snippet
  # ledger write, error summaries) could violate its own constraint and
  # fail the write — the same re-send poison class the control-byte strip
  # closes. Capping on BYTES at a codepoint boundary bounds the value
  # under EVERY counting mode (n bytes implies n codepoints implies n
  # graphemes at most), with no dependency on Ash's version-specific
  # counting API.

  @spec cap(binary(), pos_integer()) :: binary()
  def cap(text, max_bytes) when is_binary(text) do
    if byte_size(text) <= max_bytes do
      text
    else
      binary_part(text, 0, max_bytes) |> repair_boundary(3)
    end
  end

  # A cut can land inside a multi-byte sequence; drop the partial
  # sequence's leading bytes (at most 3 for UTF-8) so a valid input stays
  # valid. Input that is invalid UTF-8 beyond the boundary falls through
  # unrepaired after the budget — cap bounds size, it does not sanitize.
  defp repair_boundary(bytes, 0), do: bytes

  defp repair_boundary(bytes, budget) do
    if String.valid?(bytes) do
      bytes
    else
      bytes |> binary_part(0, byte_size(bytes) - 1) |> repair_boundary(budget - 1)
    end
  end
end
