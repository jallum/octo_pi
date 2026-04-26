defmodule OctoPi.Coder.Session.EntryTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header

  alias OctoPi.Coder.Session.Entry.{
    BranchSummary,
    Compaction,
    Custom,
    Label,
    Message,
    ModelChange,
    Passthrough,
    ThinkingLevelChange
  }

  defp roundtrip(entry) do
    json = Entry.encode(entry)
    decoded = json |> Jason.decode!() |> Entry.decode()
    {json, decoded}
  end

  describe "Header" do
    test "round-trip preserves all fields and emits camelCase parentSession" do
      h = %Header{
        version: 3,
        id: "sess-1",
        timestamp: "2026-04-26T00:00:00Z",
        cwd: "/tmp/x",
        parent_session: "parent-1"
      }

      json = Header.encode(h)
      assert json =~ ~s("parentSession":"parent-1")
      decoded = json |> Jason.decode!() |> Header.decode()
      assert decoded == h
    end

    test "header key order is type, version, id, timestamp, cwd, parentSession" do
      h = %Header{
        version: 3,
        id: "i",
        timestamp: "t",
        cwd: "/c",
        parent_session: nil
      }

      json = Header.encode(h)

      assert json =~
               ~r/^{"type":"session","version":3,"id":"[^"]+","timestamp":"[^"]+","cwd":"[^"]+","parentSession":null}$/
    end
  end

  describe "MessageEntry" do
    test "round-trip preserves opaque message map" do
      m = %Message{
        id: "e1",
        parent_id: nil,
        timestamp: "t",
        message: %{"role" => "user", "content" => "hi", "timestamp" => 1}
      }

      {json, decoded} = roundtrip(m)
      assert json =~ ~s("type":"message")
      assert json =~ ~s("parentId":null)
      assert decoded == m
    end
  end

  describe "CompactionEntry" do
    test "round-trip with all fields uses camelCase keys" do
      c = %Compaction{
        id: "c1",
        parent_id: "p1",
        timestamp: "t",
        summary: "sum",
        first_kept_entry_id: "k1",
        tokens_before: 1234,
        from_hook: true,
        details: %{"foo" => "bar"}
      }

      {json, decoded} = roundtrip(c)
      assert json =~ ~s("type":"compaction")
      assert json =~ ~s("firstKeptEntryId":"k1")
      assert json =~ ~s("tokensBefore":1234)
      assert json =~ ~s("fromHook":true)
      assert decoded == c
    end

    test "omits optional fromHook and details when nil" do
      c = %Compaction{
        id: "c1",
        parent_id: nil,
        timestamp: "t",
        summary: "s",
        first_kept_entry_id: "k",
        tokens_before: 0
      }

      {json, decoded} = roundtrip(c)
      refute json =~ "fromHook"
      refute json =~ "details"
      assert decoded == c
    end
  end

  describe "BranchSummaryEntry" do
    test "round-trip preserves fromId and details" do
      b = %BranchSummary{
        id: "b1",
        parent_id: "p1",
        timestamp: "t",
        from_id: "f1",
        summary: "s",
        from_hook: false,
        details: nil
      }

      {json, decoded} = roundtrip(b)
      assert json =~ ~s("type":"branch_summary")
      assert json =~ ~s("fromId":"f1")
      assert json =~ ~s("fromHook":false)
      assert decoded == b
    end
  end

  describe "ThinkingLevelChangeEntry" do
    test "round-trip" do
      e = %ThinkingLevelChange{
        id: "x",
        parent_id: nil,
        timestamp: "t",
        thinking_level: "high"
      }

      {json, decoded} = roundtrip(e)
      assert json =~ ~s("type":"thinking_level_change")
      assert json =~ ~s("thinkingLevel":"high")
      assert decoded == e
    end
  end

  describe "ModelChangeEntry" do
    test "round-trip" do
      e = %ModelChange{
        id: "x",
        parent_id: nil,
        timestamp: "t",
        provider: "anthropic",
        model_id: "claude-opus-4-7"
      }

      {json, decoded} = roundtrip(e)
      assert json =~ ~s("provider":"anthropic")
      assert json =~ ~s("modelId":"claude-opus-4-7")
      assert decoded == e
    end
  end

  describe "LabelEntry" do
    test "round-trip preserves nil label (deletion marker)" do
      e = %Label{
        id: "l1",
        parent_id: nil,
        timestamp: "t",
        target_id: "t1",
        label: nil
      }

      {json, decoded} = roundtrip(e)
      assert json =~ ~s("targetId":"t1")
      assert json =~ ~s("label":null)
      assert decoded == e
    end

    test "round-trip with string label" do
      e = %Label{
        id: "l1",
        parent_id: nil,
        timestamp: "t",
        target_id: "t1",
        label: "bookmark"
      }

      {_, decoded} = roundtrip(e)
      assert decoded == e
    end
  end

  describe "CustomEntry" do
    test "round-trip with customType and data" do
      e = %Custom{
        id: "x",
        parent_id: nil,
        timestamp: "t",
        custom_type: "my-ext",
        data: %{"k" => "v"}
      }

      {json, decoded} = roundtrip(e)
      assert json =~ ~s("type":"custom")
      assert json =~ ~s("customType":"my-ext")
      assert decoded == e
    end

    test "omits data when nil" do
      e = %Custom{id: "x", parent_id: nil, timestamp: "t", custom_type: "ext", data: nil}
      {json, _} = roundtrip(e)
      refute json =~ "\"data\""
    end
  end

  describe "Passthrough (unknown type)" do
    test "preserves raw map for unknown entry type" do
      raw = %{
        "type" => "future_kind",
        "id" => "x",
        "parentId" => nil,
        "timestamp" => "t",
        "newField" => 42,
        "nested" => %{"a" => 1}
      }

      decoded = Entry.decode(raw)
      assert %Passthrough{raw: ^raw} = decoded

      json = Entry.encode(decoded)
      assert Jason.decode!(json) == raw
    end
  end

  describe "Entry.decode dispatch" do
    test "dispatches by type field to correct struct" do
      msg = %{
        "type" => "message",
        "id" => "i",
        "parentId" => nil,
        "timestamp" => "t",
        "message" => %{"role" => "user"}
      }

      assert %Message{} = Entry.decode(msg)
    end
  end
end
