defmodule OctoPi.Coder.Test.FauxResponse do
  @moduledoc false

  alias OctoPi.AI.Usage

  @type tool_call_spec :: %{id: String.t(), name: String.t(), args: map()}

  @type t :: %__MODULE__{
          text: String.t() | nil,
          tool_calls: [tool_call_spec()],
          thinking: String.t() | nil,
          stop_reason: atom() | nil,
          error: String.t() | nil,
          usage: Usage.t()
        }

  defstruct text: nil, tool_calls: [], thinking: nil, stop_reason: nil, error: nil, usage: %Usage{}
end

defmodule OctoPi.Coder.Test.FauxTransport do
  @moduledoc """
  Test transport for `octo_pi_coder` extension tests. Converts
  `FauxResponse` structs into scripted AI event sequences, one per
  `stream_to/5` call.

  Usage is identical to `OctoPi.Agent.TestSupport.FakeTransport`:
  call `set_script/1` before starting a run, call `clear/0` in
  `on_exit`. Tests must be `async: false` (single global Agent).
  """

  @behaviour OctoPi.Agent.Transport

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: E
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.ToolCall
  alias OctoPi.Coder.Test.FauxResponse

  @agent_name __MODULE__

  @doc "Install a list of `FauxResponse` structs as the scripted turns."
  @spec set_script([FauxResponse.t()]) :: :ok
  def set_script(responses) when is_list(responses) do
    ensure_agent()
    turns = Enum.map(responses, &to_events/1)
    Agent.update(@agent_name, fn _ -> turns end)
    :ok
  end

  @doc "Clear the current script (call from `on_exit`)."
  @spec clear() :: :ok
  def clear do
    if Process.whereis(@agent_name), do: Agent.stop(@agent_name)
    :ok
  end

  @impl true
  def stream_to(_model, _context, _opts, caller) do
    events =
      case Agent.get_and_update(@agent_name, fn
             [] -> {:empty, []}
             [head | rest] -> {head, rest}
           end) do
        :empty -> raise "FauxTransport: script exhausted"
        evs -> evs
      end

    {:ok,
     spawn(fn ->
       Enum.each(events, &send(caller, {self(), :event, &1}))
       send(caller, {self(), :done})
     end)}
  end

  # ── event builders ───────────────────────────────────────────────

  defp to_events(%FauxResponse{error: msg}) when is_binary(msg) do
    partial = base_assistant([])
    final = %{partial | stop_reason: :error, error_message: msg}

    [
      %E.Start{partial: partial},
      %E.Error{reason: :error, message: final}
    ]
  end

  defp to_events(%FauxResponse{tool_calls: [_ | _] = calls} = resp) do
    tool_calls =
      Enum.map(calls, fn %{id: id, name: name, args: args} ->
        %ToolCall{id: id, name: name, arguments: args}
      end)

    partial = base_assistant([])
    stop = resp.stop_reason || :tool_use
    final = %{partial | content: tool_calls, stop_reason: stop}

    [
      %E.Start{partial: partial},
      %E.Done{reason: :tool_use, message: final}
    ]
  end

  defp to_events(%FauxResponse{text: text} = resp) when is_binary(text) do
    partial0 = base_assistant([])
    partial1 = base_assistant([%Text{text: ""}])
    partial2 = base_assistant([%Text{text: text}])
    stop = resp.stop_reason || :stop
    final = %{partial2 | stop_reason: stop}

    [
      %E.Start{partial: partial0},
      %E.TextStart{content_index: 0, partial: partial1},
      %E.TextDelta{content_index: 0, delta: text, partial: partial2},
      %E.TextEnd{content_index: 0, content: text, partial: partial2},
      %E.Done{reason: :stop, message: final}
    ]
  end

  defp base_assistant(content) do
    %Assistant{
      api: :faux,
      provider: :faux,
      model: "faux-1",
      timestamp: 0,
      content: content
    }
  end

  defp ensure_agent do
    case Agent.start(fn -> [] end, name: @agent_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end

defmodule OctoPi.Coder.Test.EventCollector do
  @moduledoc """
  GenServer that collects `{:octo_pi_agent_event, event}` async
  messages from a subscribed agent session. Call `events/1` to
  retrieve the full ordered list after a run completes.
  """

  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, [])

  @doc "Return all collected events in the order they arrived."
  @spec events(pid()) :: [OctoPi.Agent.Event.t()]
  def events(pid), do: GenServer.call(pid, :events)

  @impl true
  def init([]), do: {:ok, []}

  @impl true
  def handle_call(:events, _from, events), do: {:reply, Enum.reverse(events), events}

  @impl true
  def handle_info({:octo_pi_agent_event, event}, events), do: {:noreply, [event | events]}
end

defmodule OctoPi.Coder.Test.Harness do
  @moduledoc """
  One-call factory for extension integration tests. Starts an
  `OctoPi.Agent` session wired to `FauxTransport`, an
  `EventCollector` subscribed to that session, and optionally loads
  extension factories.

  Options:
    * `:tools`     — `[OctoPi.Agent.Tool.t()]`, added to the session.
    * `:factories` — `[{id, factory_fn}]` passed to
      `Loader.load_from_factory/2`; loaded extensions are in
      `harness.extensions`.

  The returned `unsubscribe` function must be called (or delegated to
  `on_exit`) from the same process that called `create/1`, since the
  OTP Registry entry is owned by that process.
  """

  alias OctoPi.Agent.MessageLog
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Test.EventCollector
  alias OctoPi.Coder.Test.FauxTransport

  @enforce_keys [:session, :collector]
  @type t :: %__MODULE__{
          session: OctoPi.Agent.t(),
          collector: pid(),
          extensions: [OctoPi.Coder.Extension.t()],
          unsubscribe: (-> :ok)
        }

  defstruct [:session, :collector, :unsubscribe, extensions: []]

  @faux_model %Model{
    id: "faux-1",
    name: "Faux Model",
    api: :faux,
    provider: :faux,
    base_url: "https://example.com",
    context_window: 128_000,
    max_tokens: 16_384
  }

  @spec create(keyword()) :: t()
  def create(opts \\ []) do
    tools = Keyword.get(opts, :tools, [])
    factories = Keyword.get(opts, :factories, [])
    extra_extensions = Keyword.get(opts, :extensions, [])
    ctx = Context.new(%{cwd: "/tmp"})
    extensions = load_factories(factories) ++ extra_extensions

    {:ok, session} =
      OctoPi.Agent.start_loop(
        model: @faux_model,
        transport: FauxTransport,
        tools: tools,
        convert_to_llm: &OctoPi.Coder.Session.Messages.to_llm/1,
        before_tool_call: build_before_tool_call(extensions, ctx),
        after_tool_call: build_after_tool_call(extensions, ctx)
      )

    {:ok, collector} = EventCollector.start_link()
    unsubscribe = OctoPi.Agent.subscribe(session, collector, :async)

    %__MODULE__{
      session: session,
      collector: collector,
      extensions: extensions,
      unsubscribe: unsubscribe
    }
  end

  @doc "Emit `session_start` with reason `:startup` to all loaded extensions."
  @spec bind_extensions(t()) :: :ok
  def bind_extensions(%__MODULE__{extensions: extensions}) do
    ctx = Context.new(%{cwd: "/tmp"})
    Dispatcher.fire_and_forget(extensions, Event.new(:session_start, %{reason: :startup}), ctx)
  end

  @doc "Emit `session_shutdown:reload` then `session_start:reload` to all extensions."
  @spec reload(t()) :: :ok
  def reload(%__MODULE__{extensions: extensions}) do
    ctx = Context.new(%{cwd: "/tmp"})
    Dispatcher.fire_and_forget(extensions, Event.new(:session_shutdown, %{reason: :reload}), ctx)
    Dispatcher.fire_and_forget(extensions, Event.new(:session_start, %{reason: :reload}), ctx)
  end

  @doc "Return all text strings from assistant messages in the session transcript."
  @spec get_assistant_texts(t()) :: [String.t()]
  def get_assistant_texts(%__MODULE__{session: session}) do
    state = OctoPi.Agent.state(session)

    state.messages
    |> MessageLog.to_list()
    |> Enum.flat_map(&extract_text_blocks/1)
  end

  defp load_factories(factories) do
    Enum.flat_map(factories, fn {id, factory} ->
      case Loader.load_from_factory(id, factory) do
        {:ok, ext} -> [ext]
        {:error, _} -> []
      end
    end)
  end

  defp build_before_tool_call([], _ctx), do: nil

  defp build_before_tool_call(extensions, ctx) do
    fn %{id: id, name: name, arguments: args} ->
      event = Event.new(:tool_call, %{id: id, name: name, arguments: args})
      apply_tool_call_result(Dispatcher.mutate_in_place(extensions, event, ctx))
    end
  end

  defp apply_tool_call_result({:block, reason}), do: {:block, reason}
  defp apply_tool_call_result(_), do: :allow

  defp build_after_tool_call([], _ctx), do: nil

  defp build_after_tool_call(extensions, ctx) do
    fn %{id: id, name: name, arguments: args, result: result} ->
      event = Event.new(:tool_result, %{id: id, name: name, arguments: args, result: result})
      apply_tool_result_patch(Dispatcher.patch_merge(extensions, event, ctx))
    end
  end

  defp apply_tool_result_patch({:ok, patches}), do: {:patch, patches}
  defp apply_tool_result_patch(:unchanged), do: :unchanged

  defp extract_text_blocks(%Assistant{content: content}), do: Enum.flat_map(content, &text_content/1)

  defp extract_text_blocks(_), do: []

  defp text_content(%Text{text: t}), do: [t]
  defp text_content(_), do: []
end
