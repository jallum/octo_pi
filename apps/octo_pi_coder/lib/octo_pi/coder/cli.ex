defmodule OctoPi.Coder.CLI do
  @moduledoc """
  Argument parsing + mode dispatch for the `mix pi` task.

  * `OctoPi.Coder.CLI.parse_args/1` — pure arg parser (testable).
  * `OctoPi.Coder.CLI.run/1` — parses argv and dispatches to the
    selected mode. Returns an integer exit code.
  """

  alias OctoPi.AI.Model
  alias OctoPi.Coder.Modes.{Print, Rpc}
  alias OctoPi.Coder.Tools

  @default_model "claude-haiku-4-5"

  @switches [
    print: :boolean,
    mode: :string,
    model: :string,
    cwd: :string,
    help: :boolean
  ]

  @aliases [p: :print, m: :model, h: :help]

  @type opts :: %{
          mode: :print | :rpc,
          prompt: String.t() | nil,
          model: Model.t(),
          cwd: String.t()
        }

  @doc """
  Parse an argv list into a validated `opts` map, a help sentinel,
  or an error tuple.
  """
  @spec parse_args([String.t()]) ::
          {:ok, opts()} | {:help, String.t()} | {:error, String.t()}
  def parse_args(argv) do
    {switches, positional, _invalid} =
      OptionParser.parse(argv, switches: @switches, aliases: @aliases)

    cond do
      switches[:help] ->
        {:help, usage_text()}

      switches[:mode] == "rpc" ->
        {:ok, base_opts(switches) |> Map.put(:mode, :rpc) |> Map.put(:prompt, nil)}

      positional == [] and switches[:print] != true ->
        {:error, "missing prompt argument.\n\n" <> usage_text()}

      true ->
        prompt = Enum.join(positional, " ")
        {:ok, base_opts(switches) |> Map.put(:mode, :print) |> Map.put(:prompt, prompt)}
    end
  end

  defp base_opts(switches) do
    %{
      model: resolve_model(switches[:model] || @default_model),
      cwd: switches[:cwd] || File.cwd!()
    }
  end

  @doc """
  Parse argv and dispatch to the selected mode. Returns an integer
  exit code suitable for `System.halt/1`.
  """
  @spec run([String.t()]) :: integer()
  def run(argv) do
    case parse_args(argv) do
      {:help, usage} ->
        IO.write(usage)
        0

      {:error, msg} ->
        IO.puts(:stderr, msg)
        1

      {:ok, %{mode: :print} = opts} ->
        case Print.run(opts) do
          {:ok, _reason} -> 0
          {:error, _reason} -> 1
        end

      {:ok, %{mode: :rpc} = opts} ->
        run_rpc(opts)
    end
  end

  defp run_rpc(opts) do
    {:ok, session} =
      OctoPi.Agent.start_session(
        model: opts.model,
        tools: default_tools(opts.cwd)
      )

    # Spawn a dedicated forwarder process and subscribe *it* — not
    # the main CLI process, which is about to block in IO.read on
    # stdin and would never drain its mailbox.
    event_forwarder = spawn_link(fn -> forward_events() end)
    OctoPi.Agent.subscribe(session, event_forwarder, :async)

    rpc_loop(session)
    0
  end

  defp default_tools(cwd) do
    [
      Tools.Read.tool(cwd),
      Tools.Write.tool(cwd),
      Tools.Edit.tool(cwd),
      Tools.Ls.tool(cwd),
      Tools.Bash.tool(cwd),
      Tools.Grep.tool(cwd),
      Tools.Find.tool(cwd)
    ]
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
      mix pi "your prompt"                     (print mode)
      mix pi --print "your prompt"
      mix pi --mode rpc                        (JSON-line RPC server)

    Flags:
      --print, -p    force print mode (default when a prompt is given)
      --mode rpc     run as a JSON-line RPC server on stdin/stdout
      --model, -m    Anthropic model id (default: #{@default_model})
      --cwd          working dir (default: current dir)
      --help, -h     show this message
    """
  end
end
