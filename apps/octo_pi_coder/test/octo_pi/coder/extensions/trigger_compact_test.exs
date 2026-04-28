defmodule OctoPi.Coder.Extensions.TriggerCompactTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Compaction.Settings
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.TriggerCompact

  # Threshold = context_window - reserve_tokens = 200_000 - 100_000 = 100_000
  @context_window 200_000
  @reserve_tokens 100_000
  @threshold @context_window - @reserve_tokens

  defp default_settings do
    %Settings{enabled: true, reserve_tokens: @reserve_tokens, keep_recent_tokens: 20_000}
  end

  defp usage(tokens), do: %{tokens: tokens, context_window: @context_window, percent: tokens / @context_window * 100}

  defp ext_with_state(usage \\ nil, settings \\ nil) do
    {:ok, state} = Agent.start_link(fn -> %{previous_tokens: nil} end)
    {:ok, compact_calls} = Agent.start_link(fn -> [] end)

    s = settings || default_settings()

    factory = fn api ->
      api =
        API.bind_core(api, %{
          get_context_usage: fn -> usage end,
          get_compaction_settings: fn -> s end,
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

  # ── init/2 ───────────────────────────────────────────────────────────────

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

  # ── turn_end handler — no compaction ─────────────────────────────────────

  describe "turn_end handler — no compaction" do
    test "does not compact when usage is nil" do
      {ext, _, compact_calls} = ext_with_state(nil)
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      assert Agent.get(compact_calls, & &1) == []
    end

    test "does not compact when tokens stay below threshold" do
      {ext, _, compact_calls} = ext_with_state(usage(@threshold - 1))
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      handler.(Event.new(:turn_end, %{}), ctx())
      assert Agent.get(compact_calls, & &1) == []
    end

    test "does not compact on first turn above threshold (no prior crossing)" do
      {ext, _, compact_calls} = ext_with_state(usage(@threshold + 1))
      handler = hd(ext.handlers[:turn_end])
      handler.(Event.new(:turn_end, %{}), ctx())
      assert Agent.get(compact_calls, & &1) == []
    end

    test "does not compact when tokens stay above threshold across turns" do
      {:ok, state} = Agent.start_link(fn -> %{previous_tokens: @threshold + 500} end)
      {:ok, compact_calls} = Agent.start_link(fn -> [] end)

      factory = fn api ->
        api =
          API.bind_core(api, %{
            get_context_usage: fn -> usage(@threshold + 1_000) end,
            get_compaction_settings: fn -> default_settings() end,
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

    test "does not compact when settings.enabled is false" do
      disabled = %Settings{enabled: false, reserve_tokens: @reserve_tokens, keep_recent_tokens: 20_000}
      {:ok, state} = Agent.start_link(fn -> %{previous_tokens: @threshold - 1} end)
      {:ok, compact_calls} = Agent.start_link(fn -> [] end)

      factory = fn api ->
        api =
          API.bind_core(api, %{
            get_context_usage: fn -> usage(@threshold + 1) end,
            get_compaction_settings: fn -> disabled end,
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

  # ── turn_end handler — threshold crossing ────────────────────────────────

  describe "turn_end handler — threshold crossing" do
    test "compacts when tokens cross from ≤ threshold to > threshold" do
      {:ok, state} = Agent.start_link(fn -> %{previous_tokens: @threshold - 1} end)
      {:ok, compact_calls} = Agent.start_link(fn -> [] end)

      factory = fn api ->
        api =
          API.bind_core(api, %{
            get_context_usage: fn -> usage(@threshold + 1) end,
            get_compaction_settings: fn -> default_settings() end,
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

    test "only auto-compacts once on crossing — matches upstream test sequence" do
      # Mirrors trigger-compact-extension.test.ts
      # 110k → no (first call, prev=nil)
      # 120k → no (prev=110k > threshold)
      # 95k  → no (prev=120k > threshold)
      # 105k → compact! (prev=95k ≤ threshold, current > threshold)
      {:ok, state} = Agent.start_link(fn -> %{previous_tokens: nil} end)
      {:ok, compact_calls} = Agent.start_link(fn -> [] end)
      current_tokens_ref = fn -> @threshold + 10_000 end |> Agent.start_link() |> elem(1)

      factory = fn api ->
        api =
          API.bind_core(api, %{
            get_context_usage: fn ->
              t = Agent.get(current_tokens_ref, & &1)
              usage(t)
            end,
            get_compaction_settings: fn -> default_settings() end,
            compact: fn opts ->
              Agent.update(compact_calls, fn calls -> [opts | calls] end)
              :ok
            end
          })

        TriggerCompact.init(api, state)
      end

      {:ok, ext} = Loader.load_from_factory("trigger-compact", factory)
      handler = hd(ext.handlers[:turn_end])
      event = Event.new(:turn_end, %{})

      # 110k: prev=nil → no compact
      Agent.update(current_tokens_ref, fn _ -> @threshold + 10_000 end)
      handler.(event, ctx())
      assert Agent.get(compact_calls, & &1) == []

      # 120k: prev=110k > threshold → no compact
      Agent.update(current_tokens_ref, fn _ -> @threshold + 20_000 end)
      handler.(event, ctx())
      assert Agent.get(compact_calls, & &1) == []

      # 95k: prev=120k > threshold → no compact
      Agent.update(current_tokens_ref, fn _ -> @threshold - 5_000 end)
      handler.(event, ctx())
      assert Agent.get(compact_calls, & &1) == []

      # 105k: prev=95k ≤ threshold, current > threshold → compact!
      Agent.update(current_tokens_ref, fn _ -> @threshold + 5_000 end)
      handler.(event, ctx())
      assert length(Agent.get(compact_calls, & &1)) == 1
    end
  end

  # ── /trigger-compact command ──────────────────────────────────────────────

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
