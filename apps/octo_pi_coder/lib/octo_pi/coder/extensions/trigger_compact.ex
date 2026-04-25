defmodule OctoPi.Coder.Extensions.TriggerCompact do
  @moduledoc """
  Triggers context compaction when the token count crosses a threshold.
  Provides /trigger-compact for manual compaction with optional instructions.
  Ported from examples/extensions/trigger-compact.ts.
  """

  alias OctoPi.Coder.Extension.API

  @threshold_tokens 100_000

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
    current = usage && Map.get(usage, :tokens)
    previous = Agent.get(state, & &1.previous_tokens)

    Agent.update(state, fn s -> %{s | previous_tokens: current} end)

    if threshold_crossed?(previous, current) do
      api.compact.([])
    end
  end

  defp threshold_crossed?(previous, current)
       when is_integer(previous) and is_integer(current) and previous <= @threshold_tokens and
              current > @threshold_tokens, do: true

  defp threshold_crossed?(_, _), do: false

  defp do_compact(api, ""), do: api.compact.([])
  defp do_compact(api, instructions), do: api.compact.(custom_instructions: instructions)
end
