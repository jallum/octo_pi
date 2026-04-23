defmodule OctoPi.AI.SSETest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.SSE
  alias OctoPi.AI.SSE.Event

  defp decode_all(chunks) do
    {events, _final} =
      Enum.reduce(chunks, {[], SSE.new()}, fn chunk, {acc, state} ->
        {events, state} = SSE.decode(state, chunk)
        {acc ++ events, state}
      end)

    events
  end

  describe "new/0" do
    test "returns an empty state" do
      assert %SSE{buffer: <<>>, event: nil, data: []} = SSE.new()
    end
  end

  describe "decode/2 — basic events" do
    test "emits a single complete event terminated by blank line" do
      assert [%Event{event: "message_start", data: ~s({"hello":"world"})}] =
               decode_all(["event: message_start\ndata: {\"hello\":\"world\"}\n\n"])
    end

    test "emits multiple consecutive events" do
      stream = """
      event: a
      data: 1

      event: b
      data: 2

      """

      assert [
               %Event{event: "a", data: "1"},
               %Event{event: "b", data: "2"}
             ] = decode_all([stream])
    end

    test "emits an event with no event: field (event is nil)" do
      assert [%Event{event: nil, data: "payload"}] =
               decode_all(["data: payload\n\n"])
    end

    test "joins multiple data: lines with \\n" do
      assert [%Event{event: "x", data: "line1\nline2\nline3"}] =
               decode_all(["event: x\ndata: line1\ndata: line2\ndata: line3\n\n"])
    end

    test "emits an event with empty data when only event: is set" do
      assert [%Event{event: "ping", data: ""}] =
               decode_all(["event: ping\n\n"])
    end

    test "drops incomplete trailing events at EOF" do
      # No terminating blank line; nothing is emitted.
      assert [] = decode_all(["event: never\ndata: finished"])
    end

    test "empty feed produces no events" do
      assert [] = decode_all([""])
      assert [] = decode_all([<<>>, <<>>])
    end
  end

  describe "decode/2 — field parsing" do
    test "strips exactly one leading space from value" do
      assert [%Event{event: "x", data: " two-spaces"}] =
               decode_all(["event: x\ndata:  two-spaces\n\n"])
    end

    test "keeps value without leading space intact" do
      assert [%Event{event: "x", data: "no-space"}] =
               decode_all(["event:x\ndata:no-space\n\n"])
    end

    test "splits on first colon only (value may contain colons)" do
      assert [%Event{data: "a:b:c"}] =
               decode_all(["data: a:b:c\n\n"])
    end

    test "comment lines (starting with ':') are dropped" do
      assert [%Event{event: "x", data: "ok"}] =
               decode_all([": just a comment\n: another one\nevent: x\ndata: ok\n\n"])
    end

    test "unknown fields (id, retry, junk) are ignored" do
      assert [%Event{event: "x", data: "payload"}] =
               decode_all(["id: 42\nretry: 3000\njunk: whatever\nevent: x\ndata: payload\n\n"])
    end

    test "line without a colon is treated as field name, empty value" do
      # Per WHATWG: "event" alone (no colon) sets event to ""
      assert [%Event{event: "", data: "d"}] =
               decode_all(["event\ndata: d\n\n"])
    end
  end

  describe "decode/2 — line terminators" do
    test "handles \\n line endings" do
      assert [%Event{event: "a", data: "1"}] =
               decode_all(["event: a\ndata: 1\n\n"])
    end

    test "handles \\r\\n line endings" do
      assert [%Event{event: "a", data: "1"}] =
               decode_all(["event: a\r\ndata: 1\r\n\r\n"])
    end

    test "handles bare \\r line endings internally" do
      # Stream must not end with a lone \r (see moduledoc). Terminator
      # here is \r\r\n — the last \r\n closes the empty line cleanly.
      assert [%Event{event: "a", data: "1"}] =
               decode_all(["event: a\rdata: 1\r\r\n"])
    end

    test "handles mixed line endings within a single stream" do
      assert [%Event{event: "a", data: "1\n2"}] =
               decode_all(["event: a\ndata: 1\r\ndata: 2\r\r\n"])
    end
  end

  describe "decode/2 — chunking" do
    test "event split across many chunks is assembled correctly" do
      stream = "event: test\ndata: payload\n\n"
      chunks = for <<c <- stream>>, do: <<c>>

      assert [%Event{event: "test", data: "payload"}] = decode_all(chunks)
    end

    test "CRLF split across chunks still reads as a single line break" do
      # Chunk 1 ends with \r, chunk 2 starts with \n — should NOT emit an
      # empty line between them. (This is the pi-mono latent bug we fix.)
      assert [%Event{event: "a", data: "1"}] =
               decode_all(["event: a\r", "\ndata: 1\r", "\n\r", "\n"])
    end

    test "two events split at arbitrary byte boundaries" do
      stream = "event: one\ndata: 1\n\nevent: two\ndata: 2\n\n"
      # Chunk in 7-byte groups, crossing field and line boundaries
      chunks =
        stream
        |> String.graphemes()
        |> Enum.chunk_every(7)
        |> Enum.map(&Enum.join/1)

      assert [
               %Event{event: "one", data: "1"},
               %Event{event: "two", data: "2"}
             ] = decode_all(chunks)
    end
  end

  describe "decode/2 — UTF-8" do
    test "UTF-8 multi-byte chars within a line are preserved" do
      assert [%Event{data: "héllo 🌍"}] = decode_all(["data: héllo 🌍\n\n"])
    end

    test "UTF-8 multi-byte char split across chunks is preserved" do
      # The rocket emoji 🚀 is 4 bytes: F0 9F 9A 80
      <<a::binary-size(2), b::binary>> = "🚀"
      chunks = ["data: ", a, b, "\n\n"]

      assert [%Event{data: "🚀"}] = decode_all(chunks)
    end
  end
end
