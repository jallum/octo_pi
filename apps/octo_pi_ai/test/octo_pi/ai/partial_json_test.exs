defmodule OctoPi.AI.PartialJsonTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.PartialJson

  describe "repair/1 — outside strings" do
    test "passes valid JSON with no string content unchanged" do
      assert PartialJson.repair("[1, 2, 3]") == "[1, 2, 3]"
      assert PartialJson.repair("{}") == "{}"
      assert PartialJson.repair("null") == "null"
      assert PartialJson.repair("") == ""
    end

    test "does not touch backslashes outside string literals" do
      # Contrived: backslash in structural position. JSON is still
      # invalid, but repair shouldn't alter it.
      assert PartialJson.repair("\\{") == "\\{"
    end
  end

  describe "repair/1 — escapes inside strings" do
    test "valid escapes pass through unchanged" do
      assert PartialJson.repair(~s({"a":"\\n"})) == ~s({"a":"\\n"})
      assert PartialJson.repair(~s({"a":"\\t"})) == ~s({"a":"\\t"})
      assert PartialJson.repair(~s({"a":"\\r"})) == ~s({"a":"\\r"})
      assert PartialJson.repair(~s({"a":"\\""})) == ~s({"a":"\\""})
      assert PartialJson.repair(~s({"a":"\\\\"})) == ~s({"a":"\\\\"})
      assert PartialJson.repair(~s({"a":"\\/"})) == ~s({"a":"\\/"})
      assert PartialJson.repair(~s({"a":"\\b"})) == ~s({"a":"\\b"})
      assert PartialJson.repair(~s({"a":"\\f"})) == ~s({"a":"\\f"})
    end

    test "valid \\uXXXX escapes pass through" do
      assert PartialJson.repair(~s({"a":"\\u0041"})) == ~s({"a":"\\u0041"})
      assert PartialJson.repair(~s({"a":"\\uabcd"})) == ~s({"a":"\\uabcd"})
      assert PartialJson.repair(~s({"a":"\\uABCD"})) == ~s({"a":"\\uABCD"})
    end

    test "invalid escapes double the backslash" do
      # \H is not a valid JSON escape — backslash is doubled, H preserved.
      assert PartialJson.repair(~s({"a":"\\H"})) == ~s({"a":"\\\\H"})
      assert PartialJson.repair(~s({"a":"\\Q"})) == ~s({"a":"\\\\Q"})
    end

    test "invalid \\u (not 4 hex digits) doubles the backslash" do
      assert PartialJson.repair(~s({"a":"\\uZZZZ"})) == ~s({"a":"\\\\uZZZZ"})
      assert PartialJson.repair(~s({"a":"\\u12"})) == ~s({"a":"\\\\u12"})
    end

    test "lone trailing backslash in unterminated string is doubled" do
      assert PartialJson.repair(~s({"a":"foo\\)) == ~s({"a":"foo\\\\)
    end
  end

  describe "repair/1 — raw control chars inside strings" do
    test "raw tab becomes \\t" do
      assert PartialJson.repair(~s({"a":"col1\tcol2"})) == ~s({"a":"col1\\tcol2"})
    end

    test "raw LF becomes \\n" do
      assert PartialJson.repair(~s({"a":"line1\nline2"})) == ~s({"a":"line1\\nline2"})
    end

    test "raw CR becomes \\r" do
      assert PartialJson.repair(~s({"a":"one\rtwo"})) == ~s({"a":"one\\rtwo"})
    end

    test "raw backspace becomes \\b" do
      assert PartialJson.repair(~s({"a":"\b"})) == ~s({"a":"\\b"})
    end

    test "raw form feed becomes \\f" do
      assert PartialJson.repair(~s({"a":"\f"})) == ~s({"a":"\\f"})
    end

    test "other raw control chars become \\uXXXX" do
      assert PartialJson.repair(~s({"a":"\x01"})) == ~s({"a":"\\u0001"})
      assert PartialJson.repair(~s({"a":"\x1f"})) == ~s({"a":"\\u001f"})
    end

    test "raw control chars outside strings are left alone" do
      assert PartialJson.repair("{\n  \"a\": 1\n}") == "{\n  \"a\": 1\n}"
    end
  end

  describe "repair/1 — multi-byte UTF-8" do
    test "passes UTF-8 chars inside strings through unchanged" do
      assert PartialJson.repair(~s({"a":"héllo 🌍"})) == ~s({"a":"héllo 🌍"})
    end
  end

  describe "parse_with_repair/1 — success path" do
    test "parses valid JSON as-is" do
      assert {:ok, %{"a" => 1}} = PartialJson.parse_with_repair(~s({"a":1}))
      assert {:ok, [1, 2, 3]} = PartialJson.parse_with_repair("[1,2,3]")
      assert {:ok, "hello"} = PartialJson.parse_with_repair(~s("hello"))
    end

    test "repairs malformed JSON and parses — pi-mono fixture" do
      # From tmp/pi-mono/packages/ai/test/anthropic-sse-parsing.test.ts:43-111.
      # \H is an invalid escape; literal tab is a raw control char inside
      # a string. After repair both become valid and the JSON parses.
      fixture = ~s({"path":"A\\H","text":"col1\tcol2"})
      assert {:ok, result} = PartialJson.parse_with_repair(fixture)
      assert result == %{"path" => "A\\H", "text" => "col1\tcol2"}
    end

    test "returns original error when repair does not change anything" do
      # Genuinely broken JSON with no repair opportunity.
      assert {:error, _} = PartialJson.parse_with_repair("not json")
      assert {:error, _} = PartialJson.parse_with_repair("{,}")
    end
  end

  describe "parse_streaming/1 — trivial inputs" do
    test "nil returns %{}" do
      assert PartialJson.parse_streaming(nil) == %{}
    end

    test "empty string returns %{}" do
      assert PartialJson.parse_streaming("") == %{}
    end

    test "whitespace-only returns %{}" do
      assert PartialJson.parse_streaming("   \n  ") == %{}
    end
  end

  describe "parse_streaming/1 — complete JSON" do
    test "parses a complete object" do
      assert PartialJson.parse_streaming(~s({"a":1,"b":"two"})) ==
               %{"a" => 1, "b" => "two"}
    end

    test "returns %{} for a complete non-object (array)" do
      assert PartialJson.parse_streaming("[1,2,3]") == %{}
    end

    test "returns %{} for a complete primitive" do
      assert PartialJson.parse_streaming("42") == %{}
      assert PartialJson.parse_streaming(~s("hello")) == %{}
      assert PartialJson.parse_streaming("true") == %{}
    end
  end

  describe "parse_streaming/1 — partial objects" do
    test "unterminated string value is closed" do
      assert PartialJson.parse_streaming(~s({"city": "Sea)) ==
               %{"city" => "Sea"}
    end

    test "unclosed object is closed" do
      assert PartialJson.parse_streaming(~s({"city": "Seattle")) ==
               %{"city" => "Seattle"}
    end

    test "trailing comma is dropped" do
      assert PartialJson.parse_streaming(~s({"city": "Seattle",)) ==
               %{"city" => "Seattle"}
    end

    test "trailing colon yields %{} (incomplete pair)" do
      assert PartialJson.parse_streaming(~s({"city":)) == %{}
    end

    test "nested partial object is closed" do
      assert PartialJson.parse_streaming(~s({"a": {"b": "c)) ==
               %{"a" => %{"b" => "c"}}
    end

    test "nested partial array in progress is closed" do
      assert PartialJson.parse_streaming(~s({"a": [1, 2)) ==
               %{"a" => [1, 2]}
    end
  end

  describe "parse_streaming/1 — incremental Anthropic-style deltas" do
    test "parses each step of a growing tool-call argument string" do
      # Simulates the arguments of a tool-call as input_json_delta chunks
      # accumulate. We assert what the parser returns at each step.
      stages = [
        {"{", %{}},
        {~s({"), %{}},
        {~s({"ci), %{}},
        {~s({"city), %{}},
        {~s({"city"), %{}},
        {~s({"city":), %{}},
        {~s({"city": "), %{"city" => ""}},
        {~s({"city": "Se), %{"city" => "Se"}},
        {~s({"city": "Seattle"), %{"city" => "Seattle"}},
        {~s({"city": "Seattle",), %{"city" => "Seattle"}},
        {~s({"city": "Seattle", "state": "WA"}), %{"city" => "Seattle", "state" => "WA"}}
      ]

      for {json, expected} <- stages do
        assert PartialJson.parse_streaming(json) == expected,
               "input: #{inspect(json)}"
      end
    end

    test "handles pi-mono repair fixture mid-stream" do
      # \H and raw tab both present; should still return a map when parsed
      # streamingly.
      mid = ~s({"path":"A\\H","text":"col1\tcol)
      assert %{"path" => "A\\H"} = PartialJson.parse_streaming(mid)
    end
  end

  describe "parse_streaming/1 — explicit pi-mono deviation" do
    # pi-mono's parseStreamingJson returns whatever JSON.parse yields
    # (arrays, primitives, empty-object fallback). We narrow the
    # contract to "always a map"; non-map parses are coerced to %{}.
    # These tests pin the deviation — a future refactor that widens
    # the return has to update them explicitly.
    #
    # See moduledoc in partial_json.ex + docs/port-map/anthropic.md §4.
    # Ticket: opi-hgb.5.

    test "well-formed array coerces to %{}" do
      assert PartialJson.parse_streaming("[1, 2, 3]") == %{}
    end

    test "well-formed primitive coerces to %{}" do
      assert PartialJson.parse_streaming("42") == %{}
      assert PartialJson.parse_streaming(~s("hello")) == %{}
      assert PartialJson.parse_streaming("true") == %{}
      assert PartialJson.parse_streaming("null") == %{}
    end

    test "partial array falls through to %{} (pi-mono would yield partial [1, 2])" do
      assert PartialJson.parse_streaming("[1, 2,") == %{}
    end
  end

  describe "parse_streaming/1 — edge cases in unterminated strings" do
    # Realistic tool-call streams hit these mid-arrival; regression-test
    # them so a refactor of close_partial/scan_brackets stays honest.

    test "escaped quote inside an unterminated string survives close" do
      assert PartialJson.parse_streaming(~s({"regex": "a\\"b)) ==
               %{"regex" => "a\"b"}
    end

    test "backslash at end of unterminated string is repaired" do
      # Raw backslash as last char of an in-flight string. repair/1 doubles
      # it so Jason parses the resulting {"path":"x\\"} to path=~S(x\).
      assert PartialJson.parse_streaming(~s({"path":"x\\)) == %{"path" => "x\\"}
    end

    test "array value mid-stream is closed" do
      assert PartialJson.parse_streaming(~s({"cmd": ["ls", "-la)) ==
               %{"cmd" => ["ls", "-la"]}
    end

    test "nested object with unterminated leaf string closes both" do
      assert PartialJson.parse_streaming(~s({"a": {"b": "c)) ==
               %{"a" => %{"b" => "c"}}
    end
  end
end
