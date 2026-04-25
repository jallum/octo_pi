defmodule OctoPi.Coder.Extensions.TriggerCompactTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.TriggerCompact

  @threshold 100_000

  defp ext_with_state(usage \\ nil) do
    {:ok, state} = Agent.start_link(fn -> %{previous_tokens: nil} end)
    {:ok, compact_calls} = Agent.start_link(fn -> [] end)

    factory = fn api ->
      api =
        API.bind_core(api, %{
          get_context_usage: fn -> usage end,
          compact: fn opts ->
            Agent.update(compact_calls, fn calls -> [opts | calls] end)
            :ok
          end
        })

      TriggerCompact.init(api, state)
    end

    {:ok, ext} = Loader.load_from_factory("trigger-compact", factory)
    {ext, state, compact_calls}
  end

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  describe "init/2" do
    test "registers a turn_end handler" do
      {ext, _, _} = ext_with_state()
      assert Map.has_key?(ext.handlers, :turn_end)
      assert length(ext.handlers[:turn_end]) == 1
    end

    test "registers a 'trigger-compact' command" do
      {ext, _, _} = ext_with_state()
      assert Map.has_key?(ext.commands, "trigger-compact")
    end

    test "'trigger-compact' has expected description" do
      {ext, _, _} = ext_with_state()
      assert ext.commands["trigger-compact"].description =~ "compact"
    end

    test "registers no tools" do
      {ext, _, _} = ext_with_state()
      assert ext.tools == %{}
    end
  end

  describe "turn_end handler — no compaction" do
    test "does not compact when usage is nil" do
      {ext, _, compact_calls} = ext_with_state(nil)
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      assert Agent.get(compact_calls, & &1) == []
    end

    test "does not compact when tokens stay below threshold" do
      usage = %{tokens: @threshold - 1}
      {ext, _, compact_calls} = ext_with_state(usage)
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      handler.(Event.new(:turn_end, %{}), ctx())
      assert Agent.get(compact_calls, & &1) == []
    end

    test "does not compact on first turn above threshold (no prior value)" do
      usage = %{tokens: @threshold + 1}
      {ext, _, compact_calls} = ext_with_state(usage)
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      assert Agent.get(compact_calls, & &1) == []
    end
  end

  describe "turn_end handler — threshold crossing" do
    test "compacts when tokens cross threshold between turns" do
      {:ok, state} = Agent.start_link(fn -> %{previous_tokens: @threshold - 1} end)
      {:ok, compact_calls} = Agent.start_link(fn -> [] end)

      factory = fn api ->
        api =
          API.bind_core(api, %{
            get_context_usage: fn -> %{tokens: @threshold + 1} end,
            compact: fn opts ->
              Agent.update(compact_calls, fn calls -> [opts | calls] end)
              :ok
            end
          })

        TriggerCompact.init(api, state)
      end

      {:ok, ext} = Loader.load_from_factory("trigger-compact", factory)
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      assert length(Agent.get(compact_calls, & &1)) == 1
    end

    test "does not compact again on subsequent turns above threshold" do
      {:ok, state} = Agent.start_link(fn -> %{previous_tokens: @threshold + 500} end)
      {:ok, compact_calls} = Agent.start_link(fn -> [] end)

      factory = fn api ->
        api =
          API.bind_core(api, %{
            get_context_usage: fn -> %{tokens: @threshold + 1000} end,
            compact: fn opts ->
              Agent.update(compact_calls, fn calls -> [opts | calls] end)
              :ok
            end
          })

        TriggerCompact.init(api, state)
      end

      {:ok, ext} = Loader.load_from_factory("trigger-compact", factory)
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      assert Agent.get(compact_calls, & &1) == []
    end
  end

  describe "/trigger-compact command" do
    test "calls compact with no options when args are empty" do
      {ext, _, compact_calls} = ext_with_state()
      ext.commands["trigger-compact"].handler.("", ctx())
      calls = Agent.get(compact_calls, & &1)
      assert length(calls) == 1
      assert hd(calls) == []
    end

    test "calls compact with custom_instructions when args are provided" do
      {ext, _, compact_calls} = ext_with_state()
      ext.commands["trigger-compact"].handler.("focus on key decisions", ctx())
      calls = Agent.get(compact_calls, & &1)
      assert length(calls) == 1
      assert hd(calls) == [custom_instructions: "focus on key decisions"]
    end

    test "trims whitespace from instructions" do
      {ext, _, compact_calls} = ext_with_state()
      ext.commands["trigger-compact"].handler.("  my instructions  ", ctx())
      calls = Agent.get(compact_calls, & &1)
      assert hd(calls) == [custom_instructions: "my instructions"]
    end
  end
end
