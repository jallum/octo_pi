defmodule OctoPi.AI.SanitizeUnicodeTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.SanitizeUnicode

  test "preserves valid UTF-8 strings" do
    assert SanitizeUnicode.sanitize("Hello world") == "Hello world"
  end

  test "preserves emoji" do
    assert SanitizeUnicode.sanitize("Hello 🙈 World") == "Hello 🙈 World"
  end

  test "strips invalid byte sequences" do
    invalid = <<"Text ", 0xFF, " here">>
    assert SanitizeUnicode.sanitize(invalid) == "Text  here"
  end

  test "strips surrogate-like bytes" do
    # 0xED 0xA0 0x80 is the UTF-8 encoding of U+D800 (high surrogate)
    # which is invalid in UTF-8
    invalid = <<"Text ", 0xED, 0xA0, 0x80, " here">>
    assert SanitizeUnicode.sanitize(invalid) == "Text  here"
  end

  test "returns empty string for all-invalid bytes" do
    assert SanitizeUnicode.sanitize(<<0xFF, 0xFE>>) == ""
  end
end
