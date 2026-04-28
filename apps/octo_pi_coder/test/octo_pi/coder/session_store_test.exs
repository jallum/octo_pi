defmodule OctoPi.Coder.SessionStoreTest do
  use ExUnit.Case, async: false

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
end
