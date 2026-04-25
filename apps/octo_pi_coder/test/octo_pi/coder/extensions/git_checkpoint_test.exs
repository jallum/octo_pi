defmodule OctoPi.Coder.Extensions.GitCheckpointTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.GitCheckpoint

  defp ext_with_exec(exec_fn) do
    {:ok, checkpoints} = Agent.start_link(fn -> %{} end)

    factory = fn api ->
      api = API.bind_core(api, %{exec: exec_fn})
      GitCheckpoint.init(api, checkpoints)
    end

    {:ok, ext} = Loader.load_from_factory("git-checkpoint", factory)
    {ext, checkpoints}
  end

  defp no_ui_ctx, do: Context.new(%{cwd: "/tmp"})

  defp ui_ctx(choice) do
    ui = %UIContext{select: fn _opts, _kw -> {:ok, choice} end, notify: fn _msg -> :ok end}
    Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})
  end

  describe "init/2" do
    test "registers a turn_start handler" do
      {ext, _} = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      assert Map.has_key?(ext.handlers, :turn_start)
    end

    test "registers a session_before_fork handler" do
      {ext, _} = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      assert Map.has_key?(ext.handlers, :session_before_fork)
    end

    test "registers an agent_end handler" do
      {ext, _} = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      assert Map.has_key?(ext.handlers, :agent_end)
    end

    test "registers no tools or commands" do
      {ext, _} = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      assert ext.tools == %{}
      assert ext.commands == %{}
    end
  end

  describe "turn_start handler" do
    test "calls git stash create" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        send(test_pid, {:exec, cmd, args})
        %{stdout: "abc123\n", code: 0}
      end

      {ext, _} = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:turn_start])
      handler.(Event.new(:turn_start, %{}), no_ui_ctx())

      assert_receive {:exec, "git", ["stash", "create"]}
    end

    test "stores a non-empty stash ref in checkpoints" do
      {ext, checkpoints} = ext_with_exec(fn _cmd, _args -> %{stdout: "abc123\n", code: 0} end)
      handler = hd(ext.handlers[:turn_start])
      handler.(Event.new(:turn_start, %{}), no_ui_ctx())
      assert map_size(Agent.get(checkpoints, & &1)) == 1
    end

    test "does not store empty stash ref (no changes to stash)" do
      {ext, checkpoints} = ext_with_exec(fn _cmd, _args -> %{stdout: "\n", code: 0} end)
      handler = hd(ext.handlers[:turn_start])
      handler.(Event.new(:turn_start, %{}), no_ui_ctx())
      assert map_size(Agent.get(checkpoints, & &1)) == 0
    end
  end

  describe "session_before_fork handler — no UI" do
    test "returns nil without prompting when has_ui? is false" do
      {ext, checkpoints} =
        ext_with_exec(fn _cmd, _args -> %{stdout: "abc123\n", code: 0} end)

      Agent.update(checkpoints, &Map.put(&1, 1, "abc123"))

      handler = hd(ext.handlers[:session_before_fork])
      result = handler.(Event.new(:session_before_fork, %{entry_id: "x"}), no_ui_ctx())
      assert is_nil(result)
    end
  end

  describe "session_before_fork handler — with UI" do
    test "applies stash when user selects :yes" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        send(test_pid, {:exec, cmd, args})
        %{stdout: "", code: 0}
      end

      {ext, checkpoints} = ext_with_exec(exec_fn)
      Agent.update(checkpoints, &Map.put(&1, 1, "abc123"))

      handler = hd(ext.handlers[:session_before_fork])
      handler.(Event.new(:session_before_fork, %{entry_id: "x"}), ui_ctx(:yes))

      assert_receive {:exec, "git", ["stash", "apply", "abc123"]}
    end

    test "does not apply stash when user selects :no" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        send(test_pid, {:exec, cmd, args})
        %{stdout: "", code: 0}
      end

      {ext, checkpoints} = ext_with_exec(exec_fn)
      Agent.update(checkpoints, &Map.put(&1, 1, "abc123"))

      handler = hd(ext.handlers[:session_before_fork])
      handler.(Event.new(:session_before_fork, %{entry_id: "x"}), ui_ctx(:no))

      refute_receive {:exec, "git", ["stash", "apply", _]}
    end

    test "does nothing when no checkpoints exist" do
      test_pid = self()

      exec_fn = fn cmd, args ->
        send(test_pid, {:exec, cmd, args})
        %{stdout: "", code: 0}
      end

      {ext, _} = ext_with_exec(exec_fn)
      handler = hd(ext.handlers[:session_before_fork])
      result = handler.(Event.new(:session_before_fork, %{entry_id: "x"}), ui_ctx(:yes))
      assert is_nil(result)
      refute_receive {:exec, _, _}
    end
  end

  describe "agent_end handler" do
    test "clears all checkpoints" do
      {ext, checkpoints} = ext_with_exec(fn _cmd, _args -> %{stdout: "", code: 0} end)
      Agent.update(checkpoints, &Map.put(&1, 1, "ref1"))
      Agent.update(checkpoints, &Map.put(&1, 2, "ref2"))

      handler = hd(ext.handlers[:agent_end])
      handler.(Event.new(:agent_end, %{}), no_ui_ctx())

      assert Agent.get(checkpoints, & &1) == %{}
    end
  end
end
