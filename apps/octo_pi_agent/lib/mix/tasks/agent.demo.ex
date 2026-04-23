defmodule Mix.Tasks.Agent.Demo do
  @shortdoc "Run a prompt through OctoPi.Agent against Anthropic."

  @moduledoc """
  End-to-end demo of `OctoPi.Agent` against live Anthropic traffic.
  Starts a session with an echo tool registered and streams events
  to stdout. Proves the full kernel (Session, loop, tool dispatch,
  subscribers, transport) round-trips end-to-end.

  ## Usage

      ANTHROPIC_API_KEY=sk-... mix agent.demo "say hi via echo"

      # Override the default model:
      ANTHROPIC_API_KEY=sk-... mix agent.demo "hi" --model claude-sonnet-4-5
  """

  use Mix.Task

  alias OctoPi.Agent.Event
  alias OctoPi.AI.{Content, Model}

  @default_model "claude-haiku-4-5"

  @switches [model: :string, help: :boolean]
  @aliases [m: :model, h: :help]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    Application.ensure_all_started(:octo_pi_ai_anthropic)
    Application.ensure_all_started(:octo_pi_agent)

    {opts, positional, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] -> Mix.shell().info(usage_text())
      positional == [] -> exit_with("error: missing prompt argument.\n\n" <> usage_text())
      true -> run_demo(Enum.join(positional, " "), opts)
    end
  end

  defp run_demo(prompt, opts) do
    model = model_for(opts[:model] || @default_model)

    system_prompt =
      "You have an 'echo' tool that returns whatever text you pass it. " <>
        "Use it if the user asks you to echo something."

    {:ok, session} =
      OctoPi.Agent.start_session(
        model: model,
        system_prompt: system_prompt,
        tools: [echo_tool()]
      )

    OctoPi.Agent.subscribe(session, self(), :async)

    Mix.shell().info("-> #{model.id}\n")

    :ok = OctoPi.Agent.prompt(session, prompt)
    loop_until_end("")
  end

  # `printed` tracks how much of the current partial assistant's
  # text we've already written to stdout so each MessageUpdate only
  # prints the new delta. It resets to "" when the assistant message
  # ends.
  defp loop_until_end(printed) do
    receive do
      {:octo_pi_agent_event, %Event.MessageUpdate{partial: p}} ->
        loop_until_end(print_latest_text_delta(p, printed))

      {:octo_pi_agent_event, %Event.MessageEnd{}} ->
        loop_until_end("")

      {:octo_pi_agent_event, %Event.ToolExecutionStart{tool_name: name}} ->
        IO.write("\n[tool_use: #{name}] ")
        loop_until_end(printed)

      {:octo_pi_agent_event, %Event.ToolExecutionEnd{result: result}} ->
        text = result.content |> Enum.map_join("", fn %Content.Text{text: t} -> t end)
        IO.write("<- #{text}\n")
        loop_until_end(printed)

      {:octo_pi_agent_event, %Event.AgentEnd{reason: reason}} ->
        IO.write("\n\n-- stop: #{reason}\n")

      {:octo_pi_agent_event, _} ->
        loop_until_end(printed)
    after
      60_000 ->
        Mix.shell().error("\n[timeout] agent didn't finish in 60s")
        exit({:shutdown, 1})
    end
  end

  defp print_latest_text_delta(%{content: content}, printed) do
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

  defp print_latest_text_delta(_, printed), do: printed

  defp echo_tool do
    %OctoPi.Agent.Tool{
      name: "echo",
      label: "Echo",
      description: "Returns its input as a text block.",
      parameters: %{
        "properties" => %{"text" => %{"type" => "string"}},
        "required" => ["text"]
      },
      handler: __MODULE__.EchoHandler
    }
  end

  defp model_for(id) do
    %Model{
      id: id,
      name: id,
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 8000
    }
  end

  defp usage_text do
    """

    Usage:
      mix agent.demo "your prompt" [--model <id>]

    Flags:
      --model, -m   Anthropic model id (default: #{@default_model})
      --help,  -h   show this message
    """
  end

  defp exit_with(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end

  defmodule EchoHandler do
    @moduledoc false
    @behaviour OctoPi.Agent.Tool.Handler

    alias OctoPi.Agent.Tool.Result
    alias OctoPi.AI.Content

    @impl true
    def execute(_id, %{"text" => text}, _ref, _on_update) do
      {:ok, %Result{content: [%Content.Text{text: text}]}}
    end

    def execute(_id, args, _ref, _on_update) do
      {:ok, %Result{content: [%Content.Text{text: inspect(args)}]}}
    end
  end
end
