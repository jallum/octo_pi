defmodule OctoPi.Coder.SessionManager.LabelsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager

  # Build a minimal in-memory session from a header + body entries written to a temp file.
  defp new_session(body_jsonl \\ "") do
    tmp = Path.join(System.tmp_dir!(), "sm-labels-#{System.unique_integer()}.jsonl")

    header = ~s({"type":"session","version":3,"id":"s1","timestamp":"t","cwd":"/c"}\n)
    File.write!(tmp, header <> body_jsonl)
    {:ok, sm} = SessionManager.load(tmp)
    sm
  end

  defp add_user(sm, content \\ "hello") do
    SessionManager.add_entry(sm, %Entry.Message{
      id: nil,
      timestamp: nil,
      message: %{"role" => "user", "content" => content}
    })
  end

  describe "get_label/2" do
    test "returns nil when no label set" do
      {sm, entry} = new_session() |> add_user()
      assert SessionManager.get_label(sm, entry.id) == nil
    end

    test "returns the label after append_label_change" do
      {sm, entry} = new_session() |> add_user()
      {sm, _} = SessionManager.append_label_change(sm, entry.id, "checkpoint")
      assert SessionManager.get_label(sm, entry.id) == "checkpoint"
    end
  end

  describe "append_label_change/3" do
    test "label entry appears in entries" do
      {sm, entry} = new_session() |> add_user()
      {sm, label_entry} = SessionManager.append_label_change(sm, entry.id, "checkpoint")

      entries = SessionManager.get_entries(sm)
      found = Enum.find(entries, &match?(%Entry.Label{}, &1))
      assert found != nil
      assert found.id == label_entry.id
      assert found.target_id == entry.id
      assert found.label == "checkpoint"
    end

    test "clears label when nil passed" do
      {sm, entry} = new_session() |> add_user()
      {sm, _} = SessionManager.append_label_change(sm, entry.id, "checkpoint")
      assert SessionManager.get_label(sm, entry.id) == "checkpoint"

      {sm, _} = SessionManager.append_label_change(sm, entry.id, nil)
      assert SessionManager.get_label(sm, entry.id) == nil
    end

    test "last label wins" do
      {sm, entry} = new_session() |> add_user()
      {sm, _} = SessionManager.append_label_change(sm, entry.id, "first")
      {sm, _} = SessionManager.append_label_change(sm, entry.id, "second")
      {sm, last} = SessionManager.append_label_change(sm, entry.id, "third")

      assert SessionManager.get_label(sm, entry.id) == "third"
      assert sm.label_timestamps_by_id[entry.id] == last.timestamp
    end

    test "raises for unknown target_id" do
      sm = new_session()
      assert_raise RuntimeError, ~r/not found/, fn ->
        SessionManager.append_label_change(sm, "nope", "x")
      end
    end

    test "labels not included in build_session_context messages" do
      {sm, entry} = new_session() |> add_user()
      {sm, _} = SessionManager.append_label_change(sm, entry.id, "checkpoint")

      ctx = SessionManager.build_session_context(sm)
      assert length(ctx.messages) == 1
      assert hd(ctx.messages)["role"] == "user"
    end
  end

  describe "label persistence (reload from file)" do
    test "labels in JSONL are resolved on load" do
      {sm, msg} = new_session() |> add_user()
      {sm, label_entry} = SessionManager.append_label_change(sm, msg.id, "important")

      # Serialize all entries back to a file
      tmp = Path.join(System.tmp_dir!(), "sm-reload-#{System.unique_integer()}.jsonl")
      lines = Enum.map(sm.file_entries, &entry_to_json/1)
      File.write!(tmp, Enum.join(lines, "\n") <> "\n")

      {:ok, reloaded} = SessionManager.load(tmp)
      assert SessionManager.get_label(reloaded, msg.id) == "important"
      assert reloaded.label_timestamps_by_id[msg.id] == label_entry.timestamp
    end

    test "label cleared by nil entry is absent after reload" do
      {sm, msg} = new_session() |> add_user()
      {sm, _} = SessionManager.append_label_change(sm, msg.id, "first")
      {sm, _} = SessionManager.append_label_change(sm, msg.id, nil)

      tmp = Path.join(System.tmp_dir!(), "sm-reload-clear-#{System.unique_integer()}.jsonl")
      lines = Enum.map(sm.file_entries, &entry_to_json/1)
      File.write!(tmp, Enum.join(lines, "\n") <> "\n")

      {:ok, reloaded} = SessionManager.load(tmp)
      assert SessionManager.get_label(reloaded, msg.id) == nil
    end
  end

  # Minimal JSON serialization for round-trip tests.
  defp entry_to_json(%OctoPi.Coder.Session.Header{} = h) do
    Jason.encode!(%{
      "type" => "session",
      "version" => h.version,
      "id" => h.id,
      "timestamp" => h.timestamp,
      "cwd" => h.cwd
    })
  end

  defp entry_to_json(%Entry.Message{} = e) do
    Jason.encode!(%{
      "type" => "message",
      "id" => e.id,
      "parentId" => e.parent_id,
      "timestamp" => e.timestamp,
      "message" => e.message
    })
  end

  defp entry_to_json(%Entry.Label{} = e) do
    Jason.encode!(%{
      "type" => "label",
      "id" => e.id,
      "parentId" => e.parent_id,
      "timestamp" => e.timestamp,
      "targetId" => e.target_id,
      "label" => e.label
    })
  end
end
