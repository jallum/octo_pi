defmodule OctoPi.Agent.SessionEntryTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.SessionEntry
  alias OctoPi.Agent.SessionEntry.BranchSummaryEntry
  alias OctoPi.Agent.SessionEntry.CompactionEntry
  alias OctoPi.Agent.SessionEntry.CustomEntry
  alias OctoPi.Agent.SessionEntry.CustomMessageEntry
  alias OctoPi.Agent.SessionEntry.LabelEntry
  alias OctoPi.Agent.SessionEntry.MessageEntry
  alias OctoPi.Agent.SessionEntry.ModelChangeEntry
  alias OctoPi.Agent.SessionEntry.SessionInfoEntry
  alias OctoPi.AI.Message.User

  describe "generate_id/1" do
    test "produces an 8-character lowercase hex string" do
      id = SessionEntry.generate_id(MapSet.new())
      assert String.length(id) == 8
      assert id =~ ~r/^[0-9a-f]{8}$/
    end

    test "avoids IDs already in the set" do
      # Pre-fill all but one possible 4-byte value is impractical,
      # but we can verify it skips a known collision.
      id = SessionEntry.generate_id(MapSet.new())
      existing = MapSet.new([id])
      id2 = SessionEntry.generate_id(existing)
      refute id2 == id
      assert String.length(id2) == 8
    end

    test "generates unique IDs across many calls" do
      ids =
        Enum.reduce(1..100, MapSet.new(), fn _, set ->
          id = SessionEntry.generate_id(set)
          MapSet.put(set, id)
        end)

      assert MapSet.size(ids) == 100
    end
  end

  describe "base fields" do
    test "MessageEntry has id, parent_id, timestamp, message" do
      msg = %User{content: "hello", timestamp: 0}

      entry = %MessageEntry{
        id: "aabbccdd",
        parent_id: nil,
        timestamp: "2024-01-01T00:00:00Z",
        message: msg
      }

      assert entry.id == "aabbccdd"
      assert entry.parent_id == nil
      assert entry.timestamp == "2024-01-01T00:00:00Z"
      assert entry.message == msg
    end

    test "CompactionEntry has base fields plus summary, first_kept_entry_id, tokens_before, details, from_hook?" do
      entry = %CompactionEntry{
        id: "11223344",
        parent_id: "aabbccdd",
        timestamp: "2024-01-01T00:00:00Z",
        summary: "The conversation so far...",
        first_kept_entry_id: "deadbeef",
        tokens_before: 4096,
        details: %{custom: true},
        from_hook?: true
      }

      assert entry.summary == "The conversation so far..."
      assert entry.first_kept_entry_id == "deadbeef"
      assert entry.tokens_before == 4096
      assert entry.details == %{custom: true}
      assert entry.from_hook? == true
    end

    test "CompactionEntry defaults: details nil, from_hook? false" do
      entry = %CompactionEntry{
        id: "11223344",
        parent_id: nil,
        timestamp: "t",
        summary: "s",
        first_kept_entry_id: "id",
        tokens_before: 0
      }

      assert entry.details == nil
      assert entry.from_hook? == false
    end

    test "BranchSummaryEntry has from_id, summary, details, from_hook?" do
      entry = %BranchSummaryEntry{
        id: "aabbccdd",
        parent_id: "00112233",
        timestamp: "t",
        from_id: "prevleaf",
        summary: "Branch summary text",
        details: nil,
        from_hook?: false
      }

      assert entry.from_id == "prevleaf"
      assert entry.summary == "Branch summary text"
    end

    test "CustomEntry has custom_type and data" do
      entry = %CustomEntry{
        id: "aabbccdd",
        parent_id: nil,
        timestamp: "t",
        custom_type: "my_extension",
        data: %{key: "value"}
      }

      assert entry.custom_type == "my_extension"
      assert entry.data == %{key: "value"}
    end

    test "CustomEntry data defaults to nil" do
      entry = %CustomEntry{id: "a", parent_id: nil, timestamp: "t", custom_type: "x"}
      assert entry.data == nil
    end

    test "CustomMessageEntry has custom_type, content, display, details" do
      entry = %CustomMessageEntry{
        id: "aabbccdd",
        parent_id: nil,
        timestamp: "t",
        custom_type: "my_msg",
        content: "Hello from extension",
        display: true,
        details: nil
      }

      assert entry.custom_type == "my_msg"
      assert entry.content == "Hello from extension"
      assert entry.display == true
    end

    test "CustomMessageEntry display defaults to false" do
      entry = %CustomMessageEntry{
        id: "a",
        parent_id: nil,
        timestamp: "t",
        custom_type: "x",
        content: "c"
      }

      assert entry.display == false
    end

    test "ModelChangeEntry has provider and model_id" do
      entry = %ModelChangeEntry{
        id: "aabbccdd",
        parent_id: nil,
        timestamp: "t",
        provider: :anthropic,
        model_id: "claude-opus-4-7"
      }

      assert entry.provider == :anthropic
      assert entry.model_id == "claude-opus-4-7"
    end

    test "LabelEntry has entry_id and label (can be nil)" do
      entry = %LabelEntry{
        id: "aabbccdd",
        parent_id: nil,
        timestamp: "t",
        entry_id: "targetid",
        label: "my label"
      }

      assert entry.entry_id == "targetid"
      assert entry.label == "my label"

      removed = %LabelEntry{
        id: "bbccddee",
        parent_id: nil,
        timestamp: "t",
        entry_id: "targetid",
        label: nil
      }

      assert removed.label == nil
    end

    test "SessionInfoEntry has display_name" do
      entry = %SessionInfoEntry{
        id: "aabbccdd",
        parent_id: nil,
        timestamp: "t",
        display_name: "My Session"
      }

      assert entry.display_name == "My Session"
    end
  end

  describe "type union" do
    test "t() covers all eight entry types" do
      msg = %User{content: "hi", timestamp: 0}

      entries = [
        %MessageEntry{id: "a", parent_id: nil, timestamp: "t", message: msg},
        %CompactionEntry{
          id: "b",
          parent_id: nil,
          timestamp: "t",
          summary: "s",
          first_kept_entry_id: "x",
          tokens_before: 0
        },
        %BranchSummaryEntry{
          id: "c",
          parent_id: nil,
          timestamp: "t",
          from_id: "y",
          summary: "s"
        },
        %CustomEntry{id: "d", parent_id: nil, timestamp: "t", custom_type: "x"},
        %CustomMessageEntry{
          id: "e",
          parent_id: nil,
          timestamp: "t",
          custom_type: "x",
          content: "c"
        },
        %ModelChangeEntry{
          id: "f",
          parent_id: nil,
          timestamp: "t",
          provider: :anthropic,
          model_id: "m"
        },
        %LabelEntry{id: "g", parent_id: nil, timestamp: "t", entry_id: "z", label: "l"},
        %SessionInfoEntry{id: "h", parent_id: nil, timestamp: "t", display_name: "n"}
      ]

      assert length(entries) == 8
    end
  end
end
