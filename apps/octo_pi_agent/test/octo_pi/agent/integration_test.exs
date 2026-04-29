defmodule OctoPi.Agent.IntegrationTest do
  @moduledoc """
  Smoke test against real Anthropic infrastructure. Excluded by
  default; run with:

      ANTHROPIC_API_KEY=sk-... mix test --only integration

  Proves the full kernel + provider stack — Loop, loop, tool
  dispatch, Transport.Direct → OctoPi.AI.stream → Anthropic
  Producer — runs end-to-end on live traffic.
  """

  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.TestSupport.EchoTool
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model

  @tag :integration
  @tag timeout: 60_000
  test "end-to-end: echo tool roundtrip against live Anthropic" do
    Application.ensure_all_started(:octo_pi_ai_anthropic)
    # If an in-process FakePlug was left wired by an earlier test in
    # the suite, clear it so we hit the real API.
    Application.delete_env(:octo_pi_ai, :req_overrides)

    model = %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 6000
    }

    {:ok, loop} =
      OctoPi.Agent.start_loop(
        model: model,
        tools: [EchoTool.tool()],
        system_prompt:
          "You have an 'echo' tool. Call echo with text 'hello' exactly once, " <>
            "then say 'done' and stop."
      )

    OctoPi.Agent.subscribe(loop, self(), :async)

    :ok = OctoPi.Agent.prompt(loop, "Please call the echo tool now.")
    :ok = OctoPi.Agent.wait_for_idle(loop, 30_000)

    assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop, messages: msgs}}

    tool_results = Enum.filter(msgs, &match?(%Message.ToolResult{}, &1))
    refute tool_results == []
    assert Enum.any?(tool_results, &(&1.tool_name == "echo"))
  end
end
