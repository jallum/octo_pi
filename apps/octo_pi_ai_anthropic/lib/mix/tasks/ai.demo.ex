defmodule Mix.Tasks.Ai.Demo do
  @shortdoc "Stream a prompt through OctoPi.AI against Anthropic."

  @moduledoc """
  End-to-end demo of `OctoPi.AI.stream/3` against the real Anthropic
  Messages API. Proves that `octo_pi_ai`'s HTTP → SSE → decoder →
  stream pipeline runs green on live traffic.

  With `--tool`, registers a toy `get_weather` tool and runs a minimal
  tool-execution loop: when the assistant stops with `:tool_use`, the
  demo fakes a weather response, appends it to the context, and
  re-streams until the assistant reaches `:stop` (or we hit
  `@max_turns` to guard against runaway loops). Previews the fuller
  agent loop landing in Phase 2.

  ## Usage

      ANTHROPIC_API_KEY=sk-... mix ai.demo "why is the sky blue?"

      # Toy weather tool + tool loop:
      ANTHROPIC_API_KEY=sk-... mix ai.demo "poem about Seattle weather" --tool

      # Override the default model (claude-haiku-4-5):
      ANTHROPIC_API_KEY=sk-... mix ai.demo "hi" --model claude-sonnet-4-5

  Text deltas are printed inline as they arrive. On completion, prints
  a short usage summary (token counts + stop reason). On error, prints
  the message and exits non-zero.
  """

  use Mix.Task

  alias OctoPi.AI.{Content, Context, Event, Message, Model, StreamOptions, Tool, ToolCall}

  @default_model "claude-haiku-4-5"
  @max_turns 5

  @switches [model: :string, tool: :boolean, help: :boolean]
  @aliases [m: :model, t: :tool, h: :help]

  @impl Mix.Task
  def run(argv) do
    Mix.Task.run("app.config")
    # Start the Anthropic app so its Application callback registers
    # the provider in core's dispatch table. This also brings up
    # :octo_pi_ai transitively as a declared dep.
    Application.ensure_all_started(:octo_pi_ai_anthropic)

    {opts, positional, _} = OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    cond do
      opts[:help] -> print_usage()
      positional == [] -> exit_with("error: missing prompt argument.\n\n" <> usage_text())
      true -> run_demo(Enum.join(positional, " "), opts)
    end
  end

  defp run_demo(prompt, opts) do
    # Credentials are resolved lazily by Request.build (OAuth or API key,
    # via env / keychain — see OctoPi.AI.Providers.Anthropic.Auth).
    # Any failure surfaces there as a descriptive error.
    model = model_for(opts[:model] || @default_model)
    tools = if(opts[:tool], do: [weather_tool()], else: [])

    context = %Context{
      messages: [
        %Message.User{content: prompt, timestamp: :os.system_time(:millisecond)}
      ],
      tools: tools
    }

    Mix.shell().info("-> #{model.id}  (#{length(tools)} tools)\n")

    stream_turns(model, context, 1)
  end

  # Recursively stream a turn, executing tool calls and feeding their
  # results back until the assistant stops without requesting more
  # tools. Guards against runaway loops with @max_turns.
  defp stream_turns(_model, _context, turn) when turn > @max_turns do
    Mix.shell().error("\n[error] exceeded #{@max_turns} tool-loop turns — stopping")
    exit({:shutdown, 1})
  end

  defp stream_turns(model, context, turn) do
    stream_opts = %StreamOptions{max_tokens: 512, temperature: 0.2}

    final =
      model
      |> OctoPi.AI.stream(context, stream_opts)
      |> Enum.reduce(nil, &handle_event/2)

    IO.write("\n")

    case final do
      %Event.Error{} = err ->
        exit_with_error(err)

      nil ->
        exit_with("stream produced no terminal event (this shouldn't happen)\n")

      %Event.Done{reason: :tool_use, message: assistant_msg} ->
        tool_results = execute_tool_calls(assistant_msg.content)
        for tr <- tool_results, do: print_tool_result(tr)
        new_messages = context.messages ++ [assistant_msg | tool_results]
        stream_turns(model, %{context | messages: new_messages}, turn + 1)

      %Event.Done{} = done ->
        print_summary(done)
    end
  end

  # --- event printing ---

  defp handle_event(%Event.Start{}, _), do: nil
  defp handle_event(%Event.TextDelta{delta: d}, _), do: IO.write(d)

  defp handle_event(%Event.ToolCallStart{partial: msg}, _) do
    call = msg.content |> Enum.reverse() |> Enum.find(&match?(%ToolCall{}, &1))
    IO.write("\n[tool_use: #{call.name}] ")
    nil
  end

  defp handle_event(%Event.ToolCallDelta{delta: d}, _), do: IO.write(d)

  defp handle_event(%Event.ToolCallEnd{tool_call: t}, _) do
    IO.write("  (args: #{inspect(t.arguments)})")
    nil
  end

  defp handle_event(%Event.ThinkingStart{}, _), do: IO.write("\n[thinking] ")
  defp handle_event(%Event.ThinkingDelta{delta: d}, _), do: IO.write(d)
  defp handle_event(%Event.ThinkingEnd{}, _), do: IO.write("\n")

  defp handle_event(%Event.Done{} = done, _), do: done
  defp handle_event(%Event.Error{} = err, _), do: err
  defp handle_event(_, acc), do: acc

  # --- tool execution (toy) ---

  defp execute_tool_calls(content) do
    now = :os.system_time(:millisecond)

    content
    |> Enum.filter(&match?(%ToolCall{}, &1))
    |> Enum.map(fn %ToolCall{id: id, name: name, arguments: args} ->
      {text, is_error?} = run_tool(name, args)

      %Message.ToolResult{
        tool_call_id: id,
        tool_name: name,
        content: [%Content.Text{text: text}],
        is_error?: is_error?,
        timestamp: now
      }
    end)
  end

  defp run_tool("get_weather", %{"city" => city} = args) do
    units = Map.get(args, "units", "fahrenheit")
    unit_letter = units |> String.first() |> String.upcase()
    temp = :rand.uniform(30) + 50
    {"#{temp}°#{unit_letter}, overcast with a chance of drizzle in #{city}", false}
  end

  defp run_tool(name, _args) do
    {"tool '#{name}' is not implemented in this demo", true}
  end

  defp print_tool_result(%Message.ToolResult{tool_name: name, content: content, is_error?: err?}) do
    text = content |> Enum.map_join("", fn %Content.Text{text: t} -> t end)
    marker = if err?, do: "[error]", else: "<-"
    IO.puts("#{marker} [tool_result: #{name}] #{text}\n")
  end

  # --- summary ---

  defp print_summary(%Event.Done{reason: reason, message: msg}) do
    usage = msg.usage

    Mix.shell().info("""

    -- stop: #{reason}
      input: #{usage.input}  output: #{usage.output}  cache_r/w: #{usage.cache_read}/#{usage.cache_write}  total: #{usage.total_tokens}
    """)
  end

  defp exit_with_error(%Event.Error{reason: reason, message: msg}) do
    Mix.shell().error("\n[error] #{reason}: #{msg.error_message}")
    exit({:shutdown, 1})
  end

  # --- model registry (Phase 1: hard-code what we ship) ---

  defp model_for(id) do
    base = %Model{
      id: id,
      name: id,
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 8000
    }

    case id do
      "claude-haiku-4-5" -> base
      "claude-sonnet-4-5" -> %{base | context_window: 200_000, max_tokens: 64_000}
      _other -> base
    end
  end

  # --- toy tool ---

  defp weather_tool do
    %Tool{
      name: "get_weather",
      description: "Get the current weather for a named city.",
      parameters: %{
        "properties" => %{
          "city" => %{"type" => "string", "description" => "City name, e.g. 'New York'"},
          "units" => %{"type" => "string", "enum" => ["celsius", "fahrenheit"]}
        },
        "required" => ["city"]
      }
    }
  end

  # --- plumbing ---

  defp print_usage, do: Mix.shell().info(usage_text())

  defp usage_text do
    """

    Usage:
      mix ai.demo "your prompt" [--model <id>] [--tool]

    Credentials (checked in order):
      StreamOptions.api_key    (not exposed on this CLI)
      ANTHROPIC_OAUTH_TOKEN    env var
      ANTHROPIC_API_KEY        env var
      Claude Code keychain     (macOS only, if logged in)

    Flags:
      --model, -m   Anthropic model id (default: #{@default_model})
      --tool,  -t   include a toy weather tool in the context; when
                    the model calls it, the demo fakes a response and
                    re-streams so the final answer actually lands
      --help,  -h   show this message
    """
  end

  defp exit_with(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
