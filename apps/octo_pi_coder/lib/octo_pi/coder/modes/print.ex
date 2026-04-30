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
  alias OctoPi.Coder.ResourceLoader
  alias OctoPi.Coder.Session.Messages, as: SessionMessages

  @spec run(OctoPi.Coder.print_opts()) :: {:ok, atom()} | {:error, atom()}
  def run(opts) do
    prompt = Keyword.fetch!(opts, :prompt)
    model = Keyword.fetch!(opts, :model)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    tools = Keyword.get(opts, :tools, OctoPi.Coder.default_tools(cwd))
    transport = Keyword.get(opts, :transport)

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        loader = Keyword.get_lazy(opts, :resource_loader, fn -> ResourceLoader.load(cwd, nil) end)
        ResourceLoader.build_system_prompt(loader, cwd, tools)
      end)

    session_opts =
      maybe_put(
        [
          model: model,
          tools: tools,
          system_prompt: system_prompt,
          convert_to_llm: &SessionMessages.to_llm/1
        ],
        :transport,
        transport
      )

    {:ok, session} = OctoPi.Agent.start_loop(session_opts)
    OctoPi.Agent.subscribe(session, self(), :async)

    :ok = OctoPi.Agent.prompt(session, prompt)
    reason = loop()
    :ok = OctoPi.Agent.wait_for_idle(session, 60_000)

    case reason do
      r when r in [:error, :aborted] -> {:error, r}
      r -> {:ok, r}
    end
  end

  defp maybe_put(kw, _, nil), do: kw
  defp maybe_put(kw, k, v), do: Keyword.put(kw, k, v)

  defp loop do
    receive do
      {:octo_pi_agent_event, %Event.MessageBlockDelta{kind: :text, delta: delta}} ->
        IO.write(delta)
        loop()

      {:octo_pi_agent_event, %Event.ToolExecutionStart{tool_name: name}} ->
        IO.write("\n[tool_use: #{name}] ")
        loop()

      {:octo_pi_agent_event, %Event.ToolExecutionEnd{result: result}} ->
        text = tool_text(result)
        IO.write("<- #{text}\n")
        loop()

      {:octo_pi_agent_event, %Event.AgentEnd{reason: reason}} ->
        IO.write("\n")
        reason

      {:octo_pi_agent_event, _} ->
        loop()
    after
      60_000 ->
        IO.write("\n[timeout] agent didn't finish in 60s\n")
        :error
    end
  end

  defp tool_text(%{content: content}) do
    content
    |> Enum.filter(&match?(%Content.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end
end
