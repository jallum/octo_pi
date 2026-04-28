defmodule OctoPi.Coder.CLI do
  @moduledoc """
  Argument parsing + mode dispatch for the `mix pi` task.

  * `OctoPi.Coder.CLI.parse_args/1` — pure arg parser (testable).
  * `OctoPi.Coder.CLI.run/1` — parses argv and dispatches to the
    selected mode. Returns an integer exit code.
  """

  alias OctoPi.Coder.Models
  alias OctoPi.Coder.Modes.Print
  alias OctoPi.Coder.Modes.Rpc
  alias OctoPi.Coder.PromptTemplates
  alias OctoPi.Coder.ResourceLoader
  alias OctoPi.Tracer.FileBackend

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
    continue: :boolean,
    log_telemetry: :string,
    no_telemetry: :string,
    list_telemetry: :boolean
  ]

  @aliases [p: :print, m: :model, h: :help, c: :continue]

  @type opts :: %{
          mode: :print | :rpc | :interactive,
          prompt: String.t() | nil,
          model: OctoPi.AI.Model.t(),
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
      continue: switches[:continue] || false,
      log_telemetry: switches[:log_telemetry],
      no_telemetry: parse_no_telemetry(switches[:no_telemetry]),
      list_telemetry: switches[:list_telemetry] || false
    }
  end

  defp parse_no_telemetry(nil), do: []

  defp parse_no_telemetry(csv) do
    csv |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
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
    {:no_unused,
     [
       dispatch: 1,
       run_interactive: 1,
       run_rpc: 1,
       rpc_loop: 1,
       silence_console_for_tui: 0,
       setup_telemetry: 1,
       ensure_tui_available: 0
     ]}
  ]

  @spec run([String.t()]) :: integer()
  def run(argv) do
    case parse_args(argv) do
      {:help, usage} ->
        IO.write(usage)
        0

      {:ok, %{list_telemetry: true}} ->
        Enum.each(OctoPi.Tracer.registered(), fn %{id: id, description: desc} ->
          IO.puts("#{id}  #{desc}")
        end)

        0

      {:ok, %{mode: :interactive} = opts} ->
        silence_console_for_tui()
        setup_telemetry(opts)
        dispatch(opts)

      {:ok, opts} ->
        setup_telemetry(opts)
        dispatch(opts)
    end
  end

  defp silence_console_for_tui do
    :logger.remove_handler(:default)
    Logger.remove_backend(:console, flush: true)
  end

  defp setup_telemetry(%{log_telemetry: path, no_telemetry: excluded}) do
    if path, do: FileBackend.install(path)
    Enum.each(excluded, &OctoPi.Tracer.detach/1)
  end

  defp dispatch(%{mode: :print} = opts) do
    case Print.run(opts) do
      {:ok, _reason} -> 0
      {:error, _reason} -> 1
    end
  end

  defp dispatch(%{mode: :rpc} = opts), do: run_rpc(opts)
  defp dispatch(%{mode: :interactive} = opts), do: run_interactive(opts)

  defp run_interactive(opts) do
    case ensure_tui_available() do
      {:module, mod} ->
        {:ok, _} = Application.ensure_all_started(:octo_pi_tui)

        if opts.log_telemetry do
          OctoPi.Tracer.attach_all()
          Enum.each(opts.no_telemetry, &OctoPi.Tracer.detach/1)
        end

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

  defp ensure_tui_available, do: Code.ensure_loaded(OctoPi.TUI.Interactive)

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

  defp resolve_model(id), do: Models.resolve(id)

  defp usage_text do
    """

    Usage:
      mix pi "your prompt"                     (print mode)
      mix pi --print "your prompt"
      mix pi --mode rpc                        (JSON-line RPC server)

    Flags:
      --print, -p    force print mode (default when a prompt is given)
      --mode rpc     run as a JSON-line RPC server on stdin/stdout
      --model, -m    model id (default: #{@default_model};
                     claude* → Anthropic; vendor/model → OpenRouter
                     (set OPENROUTER_API_KEY); else → local Ollama)
      --cwd          working dir (default: current dir)
      --help, -h     show this message
      --continue, -c    resume the most recent session for this directory
      --log-telemetry=PATH  write all :octo_pi_tracer domain log events to PATH
      --no-telemetry=ID1,ID2  detach named telemetry handlers after startup
      --list-telemetry  print registered handler ids and descriptions, then exit
    """
  end
end
