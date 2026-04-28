defmodule OctoPi.Coder.Extensions.TriggerCompact do
  @moduledoc """
  Triggers context compaction when the context window fills past the
  `reserve_tokens` boundary. Provides /trigger-compact for manual compaction
  with optional instructions.

  Ported from `tmp/pi-mono/packages/coding-agent/examples/extensions/trigger-compact.ts`.

  ## Auto-compact logic

  On each `turn_end`, compares the previous and current token counts. Compaction
  fires when:
    1. `compaction.enabled` is true (from settings),
    2. the previous count was ≤ the reserve threshold, AND
    3. the current count exceeds the reserve threshold.

  This mirrors `shouldCompact/3` from `Compaction.Tokens` combined with the
  crossing-edge guard from the upstream example.
  """

  alias OctoPi.Coder.Compaction.Tokens
  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, state) do
    {:ok, api} = API.on(api, :turn_end, fn _event, _ctx -> check_threshold(api, state) end)

    API.register_command(api, "trigger-compact", %{
      description: "Trigger compaction immediately (optional: /trigger-compact <instructions>)",
      handler: fn args, _ctx -> do_compact(api, String.trim(args)) end
    })
  end

  defp check_threshold(api, state) do
    usage = api.get_context_usage.()
    current_tokens = usage && Map.get(usage, :tokens)
    context_window = usage && Map.get(usage, :context_window)
    previous_tokens = Agent.get(state, & &1.previous_tokens)

    Agent.update(state, fn s -> %{s | previous_tokens: current_tokens} end)

    if should_fire?(previous_tokens, current_tokens, context_window, api) do
      api.compact.([])
    end
  end

  defp should_fire?(previous, current, context_window, api)
       when is_integer(previous) and is_integer(current) and is_integer(context_window) do
    settings = api.get_compaction_settings.()

    not Tokens.should_compact?(previous, context_window, settings) and
      Tokens.should_compact?(current, context_window, settings)
  end

  defp should_fire?(_, _, _, _), do: false

  defp do_compact(api, ""), do: api.compact.([])
  defp do_compact(api, instructions), do: api.compact.(custom_instructions: instructions)
end
