defmodule OctoPi.Coder.SessionStoreTest do
  use ExUnit.Case, async: false

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header
  alias OctoPi.Coder.SessionStore

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "session-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "open/1" do
    test "creates a JSONL file and writes the header", %{tmp: tmp} do
      id = "abc-1"
      {:ok, pid} = SessionStore.open(id: id, cwd: tmp, root: tmp)

      path = SessionStore.path(pid)
      assert File.exists?(path)

      [header_line] = path |> File.read!() |> String.split("\n", trim: true)
      header = Jason.decode!(header_line)

      assert header["type"] == "session"
      assert header["version"] == 3
      assert header["id"] == id
      assert header["cwd"] == tmp
      assert is_binary(header["timestamp"])

      :ok = SessionStore.close(pid)
    end

    test "header key order is stable (type, version, id, timestamp, cwd, parentSession)",
         %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "ord", cwd: tmp, root: tmp)
      path = SessionStore.path(pid)
      header_line = path |> File.read!() |> String.split("\n", trim: true) |> hd()

      # Verify key order in the raw bytes — regex matches that
      # `type` appears before `version` appears before `id` etc.
      assert header_line =~
               ~r/^{"type":"session","version":3,"id":"[^"]+","timestamp":"[^"]+","cwd":"[^"]+","parentSession":null}$/

      :ok = SessionStore.close(pid)
    end
  end

  describe "append/2" do
    test "appends entries as JSONL lines", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "app", cwd: tmp, root: tmp)

      :ok = SessionStore.append(pid, %{"type" => "custom", "kind" => "note", "text" => "hi"})
      :ok = SessionStore.append(pid, %{"type" => "custom", "kind" => "note", "text" => "bye"})

      path = SessionStore.path(pid)
      :ok = SessionStore.close(pid)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      # Header + 2 entries.
      assert length(lines) == 3

      [_header, line2, line3] = lines
      assert Jason.decode!(line2)["text"] == "hi"
      assert Jason.decode!(line3)["text"] == "bye"
    end

    test "concurrent appends are serialized through the GenServer", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "cc", cwd: tmp, root: tmp)

      tasks =
        for i <- 1..10 do
          Task.async(fn ->
            SessionStore.append(pid, %{"type" => "custom", "n" => i})
          end)
        end

      Enum.each(tasks, &Task.await/1)
      path = SessionStore.path(pid)
      :ok = SessionStore.close(pid)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      # 1 header + 10 entries.
      assert length(lines) == 11
    end
  end

  describe "append/2 — invalid UTF-8 in text content" do
    test "survives a map with a truncated multi-byte UTF-8 sequence in a text field", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "utf8", cwd: tmp, root: tmp)

      # 0xE2 0x94 is the start of a 3-byte box-drawing char sequence; the third
      # continuation byte is missing — Jason.encode! would raise without sanitization.
      bad_text = "prefix" <> <<0xE2, 0x94>> <> "suffix"
      :ok = SessionStore.append(pid, %{"type" => "message", "text" => bad_text})

      path = SessionStore.path(pid)
      :ok = SessionStore.close(pid)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
      decoded = Jason.decode!(Enum.at(lines, 1))
      assert is_binary(decoded["text"])
    end

    test "survives deeply nested invalid UTF-8 in content blocks", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "nested", cwd: tmp, root: tmp)

      bad_content = [%{"type" => "text", "text" => <<0xFF, 0xFE>>}]
      :ok = SessionStore.append(pid, %{"type" => "message", "content" => bad_content})

      path = SessionStore.path(pid)
      :ok = SessionStore.close(pid)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
    end
  end

  describe "close/1" do
    test "flushes and the file is readable after close", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "cl", cwd: tmp, root: tmp)
      :ok = SessionStore.append(pid, %{"type" => "custom", "v" => 1})
      path = SessionStore.path(pid)
      :ok = SessionStore.close(pid)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
    end
  end

  describe "encoded cwd path" do
    test "stores at <root>/sessions/--<encoded>--/<id>.jsonl", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "enc", cwd: "/home/alice/proj", root: tmp)
      path = SessionStore.path(pid)

      assert path =~ ~r|#{Regex.escape(tmp)}/sessions/--[^/]+--/[^/]*enc\.jsonl|
      assert path =~ "home"
      :ok = SessionStore.close(pid)
    end
  end

  defp message_entry(text) do
    %Entry.Message{
      id: nil,
      parent_id: nil,
      timestamp: nil,
      message: %{"role" => "user", "content" => text}
    }
  end

  describe "append_entry/3 — typed-entry path" do
    test "mints id, links parent to current leaf, returns materialized entry", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "ae", cwd: tmp, root: tmp)

      {:ok, e1} = SessionStore.append_entry(pid, message_entry("a"))
      assert is_binary(e1.id)
      assert e1.parent_id == nil
      assert is_binary(e1.timestamp)

      {:ok, e2} = SessionStore.append_entry(pid, message_entry("b"))
      assert e2.parent_id == e1.id
      assert SessionStore.get_leaf_entry_id(pid) == e2.id

      :ok = SessionStore.close(pid)
    end

    test "honours :id and :timestamp opts", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "io", cwd: tmp, root: tmp)
      {:ok, e} = SessionStore.append_entry(pid, message_entry("x"), id: "fixed", timestamp: "T")
      assert e.id == "fixed"
      assert e.timestamp == "T"
      :ok = SessionStore.close(pid)
    end

    test "persists each entry to disk in v3 byte-stable shape", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "rt", cwd: tmp, root: tmp)
      path = SessionStore.path(pid)

      {:ok, _e1} = SessionStore.append_entry(pid, message_entry("x"))
      {:ok, _e2} = SessionStore.append_entry(pid, message_entry("y"))

      :ok = SessionStore.close(pid)
      reread = path |> SessionStore.read_entries() |> Enum.to_list()

      [%Header{}, m1, m2] = reread
      assert m1.parent_id == nil
      assert m2.parent_id == m1.id
      assert m1.message["content"] == "x"
      assert m2.message["content"] == "y"
    end
  end

  describe "read API on the in-memory tree" do
    setup %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "ra", cwd: tmp, root: tmp)
      on_exit(fn -> if Process.alive?(pid), do: SessionStore.close(pid) end)

      {:ok, e1} = SessionStore.append_entry(pid, message_entry("a"))
      {:ok, e2} = SessionStore.append_entry(pid, message_entry("b"))
      {:ok, e3} = SessionStore.append_entry(pid, message_entry("c"))

      {:ok, pid: pid, e1: e1, e2: e2, e3: e3}
    end

    test "get_entry/2 looks up by id", %{pid: pid, e2: e2} do
      assert SessionStore.get_entry(pid, e2.id) == e2
      assert SessionStore.get_entry(pid, "nope") == nil
    end

    test "get_entries/1 returns body in file order", %{pid: pid, e1: e1, e2: e2, e3: e3} do
      assert SessionStore.get_entries(pid) == [e1, e2, e3]
    end

    test "get_branch/1 walks current leaf to root", %{pid: pid, e1: e1, e2: e2, e3: e3} do
      assert SessionStore.get_branch(pid) == [e1, e2, e3]
    end

    test "get_branch/2 walks from given id to root", %{pid: pid, e1: e1, e2: e2} do
      assert SessionStore.get_branch(pid, e2.id) == [e1, e2]
    end

    test "get_leaf_entry_id/1 returns current leaf", %{pid: pid, e3: e3} do
      assert SessionStore.get_leaf_entry_id(pid) == e3.id
    end

    test "get_session_id / get_cwd surface header metadata", %{pid: pid, tmp: tmp} do
      assert SessionStore.get_session_id(pid) == "ra"
      assert SessionStore.get_cwd(pid) == tmp
    end

    test "build_session_context/1 returns a context map with messages", %{pid: pid} do
      ctx = SessionStore.build_session_context(pid)
      assert is_list(ctx.messages)
      assert length(ctx.messages) == 3
    end
  end

  describe "path/3 — single read primitive" do
    setup %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "p3", cwd: tmp, root: tmp)
      on_exit(fn -> if Process.alive?(pid), do: SessionStore.close(pid) end)

      {:ok, e1} = SessionStore.append_entry(pid, message_entry("u1"))

      {:ok, comp} =
        SessionStore.append_entry(pid, %Entry.Compaction{
          id: nil,
          timestamp: nil,
          summary: "summary",
          first_kept_entry_id: e1.id,
          tokens_before: 100
        })

      {:ok, e2} = SessionStore.append_entry(pid, message_entry("u2"))
      {:ok, e3} = SessionStore.append_entry(pid, message_entry("u3"))

      {:ok, pid: pid, e1: e1, comp: comp, e2: e2, e3: e3}
    end

    test ":root walks all the way to root", %{pid: pid, e1: e1, comp: comp, e2: e2, e3: e3} do
      assert SessionStore.path(pid, :leaf, to: :root) == [e1, comp, e2, e3]
    end

    test ":latest_compaction stops at the most recent compaction (inclusive)",
         %{pid: pid, comp: comp, e2: e2, e3: e3} do
      assert SessionStore.path(pid, :leaf, to: :latest_compaction) == [comp, e2, e3]
    end

    test ":latest_compaction falls back to :root when no compaction exists", %{tmp: tmp} do
      {:ok, pid} = SessionStore.open(id: "noc", cwd: tmp, root: tmp)
      on_exit(fn -> if Process.alive?(pid), do: SessionStore.close(pid) end)

      {:ok, a} = SessionStore.append_entry(pid, message_entry("a"))
      {:ok, b} = SessionStore.append_entry(pid, message_entry("b"))

      assert SessionStore.path(pid, :leaf, to: :latest_compaction) == [a, b]
    end

    test "to: <id> stops at that id (inclusive)", %{pid: pid, comp: comp, e2: e2, e3: e3} do
      assert SessionStore.path(pid, :leaf, to: comp.id) == [comp, e2, e3]
    end

    test "to: <id> falls back to :root when id not on path", %{pid: pid, e1: e1, comp: comp, e2: e2, e3: e3} do
      assert SessionStore.path(pid, :leaf, to: "no-such-id") == [e1, comp, e2, e3]
    end

    test "explicit leaf id walks from there", %{pid: pid, e1: e1, comp: comp, e2: e2} do
      assert SessionStore.path(pid, e2.id, to: :root) == [e1, comp, e2]
    end

    test "nil leaf returns []", %{pid: pid} do
      assert SessionStore.path(pid, nil, to: :root) == []
    end
  end

  describe "open/1 with :path (resume)" do
    test "loads an existing session and opens the file in append mode", %{tmp: tmp} do
      {:ok, p1} = SessionStore.open(id: "res", cwd: tmp, root: tmp)
      {:ok, _e1} = SessionStore.append_entry(p1, message_entry("first"))
      path = SessionStore.path(p1)
      :ok = SessionStore.close(p1)

      {:ok, p2} = SessionStore.open(path: path)
      assert SessionStore.path(p2) == path
      assert SessionStore.get_session_id(p2) == "res"
      assert [first_entry] = SessionStore.get_entries(p2)
      assert first_entry.message["content"] == "first"

      {:ok, e2} = SessionStore.append_entry(p2, message_entry("second"))
      assert e2.parent_id == first_entry.id
      :ok = SessionStore.close(p2)

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 3
    end
  end
end
