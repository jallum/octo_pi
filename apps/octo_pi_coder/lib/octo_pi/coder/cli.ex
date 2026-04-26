defmodule OctoPi.Coder.CLI do
  @moduledoc """
  Argument parsing + mode dispatch for the `mix pi` task.

  * `OctoPi.Coder.CLI.parse_args/1` — pure arg parser (testable).
  * `OctoPi.Coder.CLI.run/1` — parses argv and dispatches to the
    selected mode. Returns an integer exit code.
  """

  alias OctoPi.AI.Model
  alias OctoPi.Coder.Modes.Print
  alias OctoPi.Coder.Modes.Rpc
  alias OctoPi.Coder.PromptTemplates
  alias OctoPi.Coder.ResourceLoader

  # Matches upstream pi-mono's per-provider default for Anthropic
  # (see `tmp/pi-mono/packages/coding-agent/src/core/model-resolver.ts`
  # `defaultModelPerProvider.anthropic`). Override with `--model`.
  # The full resolver (scoped models, saved settings, provider
  # priority with valid-auth fallback) is a Phase 8 follow-up.
  @default_model "qwen3.5:latest"

  @switches [
    print: :boolean,
    mode: :string,
    model: :string,
    cwd: :string,
    help: :boolean,
    debug_render: :boolean,
    debug_events: :boolean,
    trace: :string
  ]

  @aliases [p: :print, m: :model, h: :help]

  @type opts :: %{
          mode: :print | :rpc | :interactive,
          prompt: String.t() | nil,
          model: Model.t(),
          cwd: String.t()
        }

  @doc """
  Parse an argv list into a validated `opts` map, a help sentinel,
  or an error tuple.
  """
  @spec parse_args([String.t()]) :: {:ok, opts()} | {:help, String.t()}
  def parse_args(argv) do
    {switches, positional, _invalid} =
      OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    if Keyword.get(switches, :help, false) do
      {:help, usage_text()}
    else
      {:ok, build_opts(switches, positional)}
    end
  end

  defp build_opts(switches, positional) do
    base = base_opts(switches)

    cond do
      switches[:mode] == "rpc" ->
        Map.merge(base, %{mode: :rpc, prompt: nil})

      positional == [] and switches[:print] != true ->
        Map.merge(base, %{mode: :interactive, prompt: nil})

      true ->
        Map.merge(base, %{mode: :print, prompt: Enum.join(positional, " ")})
    end
  end

  defp base_opts(switches) do
    %{
      model: resolve_model(switches[:model] || @default_model),
      cwd: switches[:cwd] || File.cwd!(),
      debug_render: switches[:debug_render] || false,
      debug_events: switches[:debug_events] || false,
      trace: switches[:trace]
    }
  end

  @doc """
  Parse argv and dispatch to the selected mode. Returns an integer
  exit code suitable for `System.halt/1`.
  """
  # Dialyzer can't infer through OptionParser.parse that parse_args
  # returns both {:ok, _} and {:help, _} — it concludes only the
  # {:help, _} branch is reachable, cascading into false "unused"
  # and "pattern can never match" warnings for every mode clause.
  @dialyzer [
    {:no_match, run: 1},
    {:no_unused, [run_interactive: 1, run_rpc: 1, rpc_loop: 1]}
  ]

  @spec run([String.t()]) :: integer()
  def run(argv) do
    case parse_args(argv) do
      {:help, usage} ->
        IO.write(usage)
        0

      {:ok, %{mode: :print} = opts} ->
        case Print.run(opts) do
          {:ok, _reason} -> 0
          {:error, _reason} -> 1
        end

      {:ok, %{mode: :rpc} = opts} ->
        run_rpc(opts)

      {:ok, %{mode: :interactive} = opts} ->
        run_interactive(opts)
    end
  end

  defp run_interactive(opts) do
    # `octo_pi_tui` is an umbrella sibling; depending on it from
    # `octo_pi_coder` would create a cycle with the TUI's dep on
    # us. Instead, resolve the module at runtime — if the TUI app
    # wasn't built into this release, gracefully tell the user.
    case Code.ensure_loaded(OctoPi.TUI.Interactive) do
      {:module, mod} ->
        # Ensure the TUI app's supervision tree (Events Registry
        # etc.) is up before Interactive.run/1 tries to register
        # subscribers against it.
        {:ok, _} = Application.ensure_all_started(:octo_pi_tui)
        tools = OctoPi.Coder.default_tools(opts.cwd)
        loader = ResourceLoader.load(opts.cwd, nil)
        system_prompt = ResourceLoader.build_system_prompt(loader, opts.cwd, tools)
        expand_fn = fn text -> PromptTemplates.expand(text, loader.prompt_templates) end

        mod.run(
          Map.to_list(
            Map.merge(opts, %{
              system_prompt: system_prompt,
              tools: tools,
              resource_loader: loader,
              expand_prompt_fn: expand_fn
            })
          )
        )

        0

      {:error, _} ->
        IO.puts(:stderr, "interactive mode requires the octo_pi_tui app")
        1
    end
  end

  defp run_rpc(opts) do
    tools = OctoPi.Coder.default_tools(opts.cwd)
    loader = ResourceLoader.load(opts.cwd, nil)
    system_prompt = ResourceLoader.build_system_prompt(loader, opts.cwd, tools)

    {:ok, session} =
      OctoPi.Agent.start_session(
        model: opts.model,
        tools: tools,
        system_prompt: system_prompt
      )

    # Spawn a dedicated forwarder process and subscribe *it* — not
    # the main CLI process, which is about to block in IO.read on
    # stdin and would never drain its mailbox.
    event_forwarder = spawn_link(fn -> forward_events() end)
    OctoPi.Agent.subscribe(session, event_forwarder, :async)

    rpc_loop(session)
    0
  end

  defp rpc_loop(session) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      {:error, reason} ->
        IO.puts(:stderr, "rpc stdin error: #{inspect(reason)}")
        :ok

      line when is_binary(line) ->
        line
        |> response_for(session)
        |> safe_emit()

        rpc_loop(session)
    end
  end

  @doc false
  @spec response_for(String.t(), pid()) :: map()
  def response_for(line, session) do
    case Rpc.parse_line(line) do
      {:ok, req} -> Rpc.handle_request(session, req)
      {:error, err} -> %{"id" => nil, "error" => %{"message" => "parse error: #{inspect(err)}"}}
    end
  end

  @doc false
  # Event-forwarder loop: blocks on `{:octo_pi_agent_event, _}`
  # messages (delivered by the agent's Subscribers registry),
  # encodes each event via `Rpc.event_to_json/1`, and emits the
  # JSON on stdout. Also handles a `{:drain, from}` marker that
  # tests use to synchronize on "all prior events processed" —
  # because BEAM mailboxes are FIFO per sender, any drain message
  # sent after the agent events is guaranteed to be processed
  # after all of them.
  def forward_events do
    receive do
      {:octo_pi_agent_event, event} ->
        event |> Rpc.event_to_json() |> safe_emit()
        forward_events()

      {:drain, from} ->
        send(from, :drained)
        forward_events()
    end
  end

  # Jason.encode! raises on non-encodable values (pids, funs,
  # certain binaries). A crash here would take down the forwarder
  # or rpc_loop and silently kill the RPC session. Emit a generic
  # error line instead so the client still sees something.
  @doc false
  @spec safe_emit(map()) :: :ok
  def safe_emit(map) do
    IO.puts(Jason.encode!(map))
  rescue
    error ->
      fallback = %{"error" => %{"message" => "encoding failed: #{Exception.message(error)}"}}
      IO.puts(Jason.encode!(fallback))
  end

  defp resolve_model(id) do
    case provider_from_model_id(id) do
      :ollama ->
        %Model{
          id: id,
          name: id,
          api: :openai_completions,
          provider: :ollama,
          base_url: "http://localhost:1234/v1",
          context_window: 262_144,
          max_tokens: 4_096
        }

      :anthropic ->
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
  end

  defp provider_from_model_id(id) do
    if String.starts_with?(id, "claude") do
      :anthropic
    else
      :ollama
    end
  end

  defp usage_text do
    """

    Usage:
      mix pi "your prompt"                     (print mode)
      mix pi --print "your prompt"
      mix pi --mode rpc                        (JSON-line RPC server)

    Flags:
      --print, -p    force print mode (default when a prompt is given)
      --mode rpc     run as a JSON-line RPC server on stdin/stdout
      --model, -m    model id (default: #{@default_model}; claude* → Anthropic, else → Ollama)
      --cwd          working dir (default: current dir)
      --help, -h     show this message
      --debug-events log stdin/key pipeline to debug_events.log
      --trace=PATH   write a timestamped tty/stdin trace to PATH (use to diagnose
                     shutdown leaks; install Tracer telemetry handler on startup)
    """
  end
end
