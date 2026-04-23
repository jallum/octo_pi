defmodule Mix.Tasks.Pi do
  @shortdoc "Run the octo_pi coding agent (Print or RPC mode)."

  @moduledoc """
  Coding-agent CLI. Two modes:

      # Print mode — single-shot prompt, streams text to stdout:
      ANTHROPIC_API_KEY=sk-... mix pi "write hello world to foo.txt"

      # RPC mode — JSON-line server on stdin/stdout:
      ANTHROPIC_API_KEY=sk-... mix pi --mode rpc

  See `mix pi --help` for the full flag list.
  """

  use Mix.Task

  alias OctoPi.Coder.CLI

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:octo_pi_ai_anthropic)
    Application.ensure_all_started(:octo_pi_agent)
    Application.ensure_all_started(:octo_pi_coder)

    case CLI.run(argv) do
      0 -> :ok
      code -> exit({:shutdown, code})
    end
  end
end
