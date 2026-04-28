defmodule OctoPi.Coder.Compaction.FileOpsTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.FileOps

  defp assistant(blocks) do
    %Assistant{
      api: :anthropic_messages,
      provider: :anthropic,
      model: "test",
      timestamp: 0,
      content: blocks,
      usage: %Usage{},
      stop_reason: :stop
    }
  end

  defp tc(name, args), do: %ToolCall{id: "id-#{name}", name: name, arguments: args}

  describe "new/0" do
    test "starts with three empty MapSets" do
      ops = FileOps.new()
      assert MapSet.size(ops.read) == 0
      assert MapSet.size(ops.written) == 0
      assert MapSet.size(ops.edited) == 0
    end
  end

  describe "extract/2" do
    test "captures read/write/edit tool calls by their path argument" do
      msg =
        assistant([
          tc("read", %{"path" => "a.ex"}),
          tc("write", %{"path" => "b.ex"}),
          tc("edit", %{"path" => "c.ex"})
        ])

      ops = FileOps.extract(msg, FileOps.new())
      assert ops.read == MapSet.new(["a.ex"])
      assert ops.written == MapSet.new(["b.ex"])
      assert ops.edited == MapSet.new(["c.ex"])
    end

    test "ignores non-tracked tool names" do
      msg = assistant([tc("bash", %{"path" => "x"}), tc("grep", %{"path" => "y"})])
      assert FileOps.extract(msg, FileOps.new()) == FileOps.new()
    end

    test "ignores tool calls without a string path argument" do
      msg =
        assistant([
          tc("read", %{}),
          tc("read", %{"path" => 123}),
          %Text{text: "noise"}
        ])

      assert FileOps.extract(msg, FileOps.new()) == FileOps.new()
    end

    test "ignores non-assistant messages" do
      ops = Map.put(FileOps.new(), :read, MapSet.new(["sentinel"]))
      assert FileOps.extract(%User{content: "hi", timestamp: 0}, ops) == ops
    end

    test "is reducible across multiple messages" do
      m1 = assistant([tc("read", %{"path" => "a"})])
      m2 = assistant([tc("write", %{"path" => "a"})])
      ops = Enum.reduce([m1, m2], FileOps.new(), &FileOps.extract/2)
      assert ops.read == MapSet.new(["a"])
      assert ops.written == MapSet.new(["a"])
    end
  end

  describe "compute_lists/1" do
    test "modified is union of written and edited; read excludes modified; both sorted" do
      ops = %FileOps{
        read: MapSet.new(["c.ex", "a.ex", "b.ex"]),
        written: MapSet.new(["b.ex"]),
        edited: MapSet.new(["d.ex"])
      }

      assert FileOps.compute_lists(ops) == %{
               read_files: ["a.ex", "c.ex"],
               modified_files: ["b.ex", "d.ex"]
             }
    end

    test "empty input yields empty lists" do
      assert FileOps.compute_lists(FileOps.new()) ==
               %{read_files: [], modified_files: []}
    end
  end

  describe "format/2" do
    test "returns empty string when both lists are empty" do
      assert FileOps.format([], []) == ""
    end

    test "renders read-files block alone, prefixed with double newline" do
      assert FileOps.format(["a", "b"], []) ==
               "\n\n<read-files>\na\nb\n</read-files>"
    end

    test "renders modified-files block alone" do
      assert FileOps.format([], ["x", "y"]) ==
               "\n\n<modified-files>\nx\ny\n</modified-files>"
    end

    test "renders both sections separated by a blank line" do
      assert FileOps.format(["a"], ["b"]) ==
               "\n\n<read-files>\na\n</read-files>\n\n<modified-files>\nb\n</modified-files>"
    end
  end
end
