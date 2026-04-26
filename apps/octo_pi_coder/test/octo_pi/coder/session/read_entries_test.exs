defmodule OctoPi.Coder.Session.ReadEntriesTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header
  alias OctoPi.Coder.SessionStore

  @fixture_root Path.expand(
                  "../../../../../../tmp/pi-mono/packages/coding-agent/test/fixtures",
                  __DIR__
                )

  describe "read_entries/1" do
    test "streams the before-compaction.jsonl fixture: header then entries" do
      path = Path.join(@fixture_root, "before-compaction.jsonl")
      assert File.exists?(path), "fixture missing at #{path}"

      [first | rest] = path |> SessionStore.read_entries() |> Enum.to_list()

      assert %Header{} = first
      assert first.cwd =~ "pi-mono"

      assert length(rest) > 0
      assert Enum.all?(rest, &is_struct/1)
    end

    test "streams the large-session.jsonl fixture and decodes known types" do
      path = Path.join(@fixture_root, "large-session.jsonl")
      entries = path |> SessionStore.read_entries() |> Enum.to_list()

      [%Header{} | rest] = entries
      counts = Enum.frequencies_by(rest, & &1.__struct__)

      assert Map.get(counts, Entry.Message, 0) > 0
      # large-session.jsonl includes model_change and thinking_level_change
      assert Map.get(counts, Entry.ModelChange, 0) > 0 or
               Map.get(counts, Entry.ThinkingLevelChange, 0) > 0
    end

    test "round-trips parse → encode → parse yielding identical structs" do
      path = Path.join(@fixture_root, "before-compaction.jsonl")
      [header | rest] = path |> SessionStore.read_entries() |> Enum.to_list()

      reencoded_lines =
        [Header.encode(header) | Enum.map(rest, &Entry.encode/1)]

      tmp = Path.join(System.tmp_dir!(), "rt-#{System.unique_integer([:positive])}.jsonl")
      File.write!(tmp, Enum.join(reencoded_lines, "\n") <> "\n")
      on_exit(fn -> File.rm(tmp) end)

      reparsed = tmp |> SessionStore.read_entries() |> Enum.to_list()
      assert reparsed == [header | rest]
    end

    test "skips malformed JSON lines silently", %{} do
      tmp = Path.join(System.tmp_dir!(), "bad-#{System.unique_integer([:positive])}.jsonl")

      File.write!(
        tmp,
        ~s({"type":"session","id":"x","timestamp":"t","cwd":"/c"}\n) <>
          "this is not json\n" <>
          ~s({"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{}}\n)
      )

      on_exit(fn -> File.rm(tmp) end)

      entries = tmp |> SessionStore.read_entries() |> Enum.to_list()
      assert [%Header{}, %Entry.Message{}] = entries
    end

    test "is lazy — does not crash if the file has no body lines" do
      tmp = Path.join(System.tmp_dir!(), "empty-#{System.unique_integer([:positive])}.jsonl")
      File.write!(tmp, ~s({"type":"session","id":"x","timestamp":"t","cwd":"/c"}\n))
      on_exit(fn -> File.rm(tmp) end)

      assert [%Header{}] = tmp |> SessionStore.read_entries() |> Enum.to_list()
    end
  end
end
