defmodule OctoPi.TUI.InteractiveIntegrationTest do
  @moduledoc """
  Live-Anthropic smoke test for the TUI Interactive mode. Excluded by
  default; opt in with

      ANTHROPIC_API_KEY=sk-... mix test --only integration

  Proves that Interactive.run/1 round-trips end-to-end against a
  real Anthropic model: types a prompt, receives a streamed response,
  and exits cleanly.
  """

  use ExUnit.Case, async: false

  alias OctoPi.AI.Model
  alias OctoPi.TUI.Interactive
  alias OctoPi.TUI.TerminalHelpers

  @tag :integration
  @tag timeout: 60_000
  test "types a prompt, receives response, exits on Ctrl+C" do
    Application.ensure_all_started(:octo_pi_ai_anthropic)
    Application.ensure_all_started(:octo_pi_agent)
    Application.ensure_all_started(:octo_pi_coder)
    Application.ensure_all_started(:octo_pi_tui)

    model = %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 6000
    }

    parent = self()
    {:ok, buffer} = Agent.start_link(fn -> [] end)

    write_fn = fn bytes ->
      bin = IO.iodata_to_binary(bytes)
      Agent.update(buffer, &[bin | &1])
      send(parent, {:tui_output, bin})
    end

    terminal_name = :"integration_terminal_#{System.unique_integer([:positive])}"

    runner =
      Task.async(fn ->
        Interactive.run(
          model: model,
          tools: [],
          write_fn: write_fn,
          skip_raw_mode: true,
          skip_sigwinch: true,
          auto_start_reader: false,
          dimensions: {80, 24},
          terminal_name: terminal_name
        )
      end)

    assert_receive {:tui_output, _initial}, 5_000

    TerminalHelpers.simulate_stdin(
      terminal_name,
      "Reply with exactly the single word 'pong' and nothing else."
    )

    TerminalHelpers.simulate_stdin(terminal_name, "\r")

    receive_until_containing("pong", 30_000)

    TerminalHelpers.simulate_stdin(terminal_name, <<0x03>>)
    assert :ok = Task.await(runner, 5_000)

    all = buffer |> Agent.get(& &1) |> Enum.reverse() |> IO.iodata_to_binary()
    assert String.downcase(all) =~ "pong"
  end

  defp receive_until_containing(needle, timeout) do
    receive do
      {:tui_output, bin} ->
        if String.downcase(bin) =~ needle,
          do: :ok,
          else: receive_until_containing(needle, timeout)
    after
      timeout -> flunk("did not see #{inspect(needle)} in any tui_output within #{timeout}ms")
    end
  end
end
