defmodule Mix.Tasks.Ai.Demo do
  @shortdoc "Stream a prompt through OctoPi.AI against Anthropic."

  @moduledoc """
  End-to-end demo of `OctoPi.AI.stream/3` against the real Anthropic
  Messages API. Proves that `octo_pi_ai`'s HTTP → SSE → decoder →
  stream pipeline runs green on live traffic.

  ## Usage

      ANTHROPIC_API_KEY=sk-... mix ai.demo "why is the sky blue?"

      # With a toy weather tool to exercise the tool-call event path:
      ANTHROPIC_API_KEY=sk-... mix ai.demo "what's the weather in NYC?" --tool

      # Override the default model (claude-haiku-4-5):
      ANTHROPIC_API_KEY=sk-... mix ai.demo "hi" --model claude-sonnet-4-5

  Text deltas are printed inline as they arrive. On completion, prints
  a short usage summary (token counts + stop reason). On error, prints
  the message and exits non-zero.
  """

  use Mix.Task

  alias OctoPi.AI.{Context, Event, Message, Model, StreamOptions, Tool}

  @default_model "claude-haiku-4-5"

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

    context = %Context{
      messages: [
        %Message.User{content: prompt, timestamp: :os.system_time(:millisecond)}
      ],
      tools: if(opts[:tool], do: [weather_tool()], else: [])
    }

    stream_opts = %StreamOptions{max_tokens: 512, temperature: 0.2}

    Mix.shell().info("→ #{model.id}  (#{length(context.tools)} tools)\n")

    final =
      model
      |> OctoPi.AI.stream(context, stream_opts)
      |> Enum.reduce(nil, &handle_event/2)

    IO.write("\n")

    case final do
      %Event.Done{} = done -> print_summary(done)
      %Event.Error{} = err -> exit_with_error(err)
      nil -> exit_with("stream produced no terminal event (this shouldn't happen)\n")
    end
  end

  # --- event printing ---

  defp handle_event(%Event.Start{}, _), do: nil
  defp handle_event(%Event.TextDelta{delta: d}, _), do: IO.write(d)

  defp handle_event(%Event.ToolCallStart{partial: msg}, _) do
    call = Enum.find(msg.content, &match?(%OctoPi.AI.ToolCall{}, &1))
    IO.write("\n[tool_use » #{call.name}] ")
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

  # --- summary ---

  defp print_summary(%Event.Done{reason: reason, message: msg}) do
    usage = msg.usage

    Mix.shell().info("""

    ─ stop: #{reason}
      input: #{usage.input}  output: #{usage.output}  cache_r/w: #{usage.cache_read}/#{usage.cache_write}  total: #{usage.total_tokens}
    """)
  end

  defp exit_with_error(%Event.Error{reason: reason, message: msg}) do
    Mix.shell().error("\n✗ #{reason}: #{msg.error_message}")
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
      --tool,  -t   include a toy weather tool in the context
      --help,  -h   show this message
    """
  end

  defp exit_with(message) do
    Mix.shell().error(message)
    exit({:shutdown, 1})
  end
end
