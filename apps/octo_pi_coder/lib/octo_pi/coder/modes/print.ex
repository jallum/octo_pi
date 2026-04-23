defmodule OctoPi.Coder.Modes.Print do
  @moduledoc """
  Non-interactive single-shot mode. Takes a prompt, runs one agent
  session to terminal stop, streams text deltas + tool-event
  markers to stdout, returns the final stop reason.

  Used by `Mix.Tasks.Pi` for `mix pi --print "..."`. Designed to be
  called programmatically too (smoke tests, batch pipelines).

  ## Options (`opts` map)

    * `:prompt`    — user prompt (required)
    * `:model`     — `%OctoPi.AI.Model{}` (required)
    * `:cwd`       — session working dir (default: `File.cwd!/0`)
    * `:tools`     — list of `%OctoPi.Agent.Tool{}` (default: the
      built-in set)
    * `:transport` — agent transport module (default:
      `OctoPi.Agent.Transport.Direct`)
    * `:system_prompt` — optional system prompt override

  Returns `{:ok, reason}` for a clean stop or `{:error, reason}`
  for `:error`/`:aborted`.
  """

  alias OctoPi.Agent.Event
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools

  @default_tools [
    Tools.Read.tool(),
    Tools.Write.tool(),
    Tools.Edit.tool(),
    Tools.Ls.tool(),
    Tools.Bash.tool(),
    Tools.Grep.tool(),
    Tools.Find.tool()
  ]

  @spec run(map()) :: {:ok, atom()} | {:error, atom()}
  def run(%{prompt: prompt, model: model} = opts) do
    tools = Map.get(opts, :tools, @default_tools)
    transport = Map.get(opts, :transport)

    session_opts =
      [model: model, tools: tools, system_prompt: opts[:system_prompt]]
      |> Keyword.reject(fn {_, v} -> is_nil(v) end)
      |> maybe_put(:transport, transport)

    {:ok, session} = OctoPi.Agent.start_session(session_opts)
    OctoPi.Agent.subscribe(session, self(), :async)

    :ok = OctoPi.Agent.prompt(session, prompt)
    reason = loop("")
    :ok = OctoPi.Agent.wait_for_idle(session, 60_000)

    case reason do
      r when r in [:error, :aborted] -> {:error, r}
      r -> {:ok, r}
    end
  end

  defp maybe_put(kw, _, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  # `printed` is how much of the current partial assistant's text
  # has already been written to stdout.
  defp loop(printed) do
    receive do
      {:octo_pi_agent_event, %Event.MessageUpdate{partial: p}} ->
        loop(print_new_text(p, printed))

      {:octo_pi_agent_event, %Event.MessageEnd{}} ->
        loop("")

      {:octo_pi_agent_event, %Event.ToolExecutionStart{tool_name: name}} ->
        IO.write("\n[tool_use: #{name}] ")
        loop(printed)

      {:octo_pi_agent_event, %Event.ToolExecutionEnd{result: result}} ->
        text = tool_text(result)
        IO.write("<- #{text}\n")
        loop(printed)

      {:octo_pi_agent_event, %Event.AgentEnd{reason: reason}} ->
        IO.write("\n")
        reason

      {:octo_pi_agent_event, _} ->
        loop(printed)
    after
      60_000 ->
        IO.write("\n[timeout] agent didn't finish in 60s\n")
        :error
    end
  end

  defp print_new_text(%{content: content}, printed) do
    text =
      content
      |> Enum.filter(&match?(%Content.Text{}, &1))
      |> Enum.map_join("", & &1.text)

    if String.starts_with?(text, printed) do
      IO.write(String.slice(text, String.length(printed)..-1//1))
      text
    else
      printed
    end
  end

  defp print_new_text(_, printed), do: printed

  defp tool_text(%{content: content}) do
    content
    |> Enum.filter(&match?(%Content.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end
end
