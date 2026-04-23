defmodule OctoPi.Coder.IntegrationTest do
  @moduledoc """
  Live-Anthropic smoke test for the coder's Print mode. Excluded by
  default; opt in with

      ANTHROPIC_API_KEY=sk-... mix test --only integration

  Proves that the full Phase 3 stack — CLI + Print mode + agent
  kernel + Anthropic provider — round-trips end-to-end against
  production traffic.
  """

  use ExUnit.Case, async: false

  alias OctoPi.AI.Model
  alias OctoPi.Coder.Modes.Print

  @tag :integration
  @tag timeout: 60_000
  test "mix pi --print equivalent with a trivial prompt works end-to-end" do
    Application.ensure_all_started(:octo_pi_ai_anthropic)
    Application.ensure_all_started(:octo_pi_agent)
    Application.ensure_all_started(:octo_pi_coder)
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

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert {:ok, reason} =
                 Print.run(%{
                   prompt: "Reply with exactly the single word 'pong' and nothing else.",
                   model: model,
                   tools: []
                 })

        assert reason in [:stop, :length]
      end)

    assert String.downcase(output) =~ "pong"
  end
end
