defmodule OctoPi.Coder.Extension.CommandContextTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.CommandContext
  alias OctoPi.Coder.Extension.Context

  defp base_ctx, do: Context.new(%{cwd: "/tmp"})

  describe "new/1" do
    test "wraps base context" do
      cmd_ctx = CommandContext.new(base_ctx())
      assert cmd_ctx.base.cwd == "/tmp"
    end

    test "all session actions are stubs" do
      cmd_ctx = CommandContext.new(base_ctx())

      assert_raise RuntimeError, ~r/interactive mode only/, fn ->
        cmd_ctx.wait_for_idle.()
      end

      assert_raise RuntimeError, ~r/interactive mode only/, fn ->
        cmd_ctx.reload.()
      end

      assert_raise RuntimeError, ~r/interactive mode only/, fn ->
        cmd_ctx.new_session.(fn _ -> :ok end)
      end

      assert_raise RuntimeError, ~r/interactive mode only/, fn ->
        cmd_ctx.switch_session.("session.jsonl")
      end

      assert_raise RuntimeError, ~r/interactive mode only/, fn ->
        cmd_ctx.fork.("entry-1", [])
      end

      assert_raise RuntimeError, ~r/interactive mode only/, fn ->
        cmd_ctx.navigate_tree.("target-id", [])
      end
    end
  end

  describe "bind/2" do
    test "replaces stubs with real implementations" do
      cmd_ctx = CommandContext.new(base_ctx())

      actions = %{
        wait_for_idle: fn -> :idle end,
        new_session: fn _cb -> :new end,
        fork: fn _id, _opts -> :forked end,
        navigate_tree: fn _id, _opts -> :navigated end,
        switch_session: fn _file -> :switched end,
        reload: fn -> :reloaded end
      }

      bound = CommandContext.bind(cmd_ctx, actions)
      assert :idle == bound.wait_for_idle.()
      assert :new == bound.new_session.(fn _ -> :ok end)
      assert :forked == bound.fork.("entry", [])
      assert :navigated == bound.navigate_tree.("target", [])
      assert :switched == bound.switch_session.("file.jsonl")
      assert :reloaded == bound.reload.()
    end

    test "partial bind leaves unbound stubs" do
      cmd_ctx = CommandContext.new(base_ctx())
      bound = CommandContext.bind(cmd_ctx, %{wait_for_idle: fn -> :ok end})

      assert :ok == bound.wait_for_idle.()
      assert_raise RuntimeError, ~r/interactive mode only/, fn -> bound.reload.() end
    end
  end
end
