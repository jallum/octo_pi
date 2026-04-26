defmodule OctoPi.Agent.ExtensionRunner do
  @moduledoc """
  GenServer that holds registered extensions and dispatches lifecycle events to
  them, one per session. Complements the `Subscribers` system (notification-only)
  by supporting cancellable and result-modifiable events.

  Event classes:

  - **Cancellable** — stopped at the first `{:cancel, reason}`; returns
    `{:cancelled, reason}`. If no extension cancels, returns `:ok`.
  - **Result-modifiable** — all `{:ok, modifications}` maps are merged in
    registration order (last-writer-wins per key); returns `{:modified, map()}`
    when any extension modifies, `:ok` otherwise.
  - **Notification-only** — all extensions are called; always returns `:ok`.
  """

  use GenServer

  # Cancelled at first {:cancel, reason}; first {:ok, mods} with non-empty map also wins.
  @compound_events ~w(session_before_compact session_before_fork session_before_tree tool_call input)a
  # All handlers called; {:ok, mods} maps are merged (last-writer-wins).
  @modifiable_events ~w(context before_provider_request after_provider_response before_agent_start tool_result)a

  # ---------- public API ----------

  @doc "Start an ExtensionRunner linked to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Register an extension module. Appended to the end of the dispatch list."
  @spec register(pid(), module()) :: :ok
  def register(pid, module) when is_atom(module) do
    GenServer.call(pid, {:register, module})
  end

  @doc "Register a slash-command handler (name without leading slash)."
  @spec register_command(pid(), String.t(), (String.t() -> :ok)) :: :ok
  def register_command(pid, name, handler) when is_binary(name) and is_function(handler, 1) do
    GenServer.call(pid, {:register_command, name, handler})
  end

  @doc "Return the current command registry map (name => handler_fn)."
  @spec get_commands(pid()) :: %{String.t() => (String.t() -> :ok)}
  def get_commands(pid) do
    GenServer.call(pid, :get_commands)
  end

  @doc """
  Emit an event to all registered extensions.

  Returns:
    - `:ok` — no cancellation, no modifications
    - `{:cancelled, reason}` — a cancellable event was cancelled
    - `{:modified, map()}` — a modifiable event returned modifications
  """
  @spec emit(pid(), atom(), map()) :: :ok | {:cancelled, term()} | {:modified, map()}
  def emit(pid, event_type, payload) do
    GenServer.call(pid, {:emit, event_type, payload})
  end

  @doc "Emit an event with additional ctx fields merged into the base ctx."
  @spec emit_with_ctx(pid(), atom(), map(), map()) :: :ok | {:cancelled, term()} | {:modified, map()}
  def emit_with_ctx(pid, event_type, payload, extra_ctx) do
    GenServer.call(pid, {:emit_with_ctx, event_type, payload, extra_ctx})
  end

  # ---------- GenServer callbacks ----------

  @impl true
  def init(opts) do
    {:ok, %{session_pid: Keyword.fetch!(opts, :session_pid), extensions: [], commands: %{}}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    {:reply, :ok, %{state | extensions: state.extensions ++ [module]}}
  end

  def handle_call({:register_command, name, handler}, _from, state) do
    {:reply, :ok, %{state | commands: Map.put(state.commands, name, handler)}}
  end

  def handle_call(:get_commands, _from, state) do
    {:reply, state.commands, state}
  end

  def handle_call({:emit, event_type, payload}, _from, state) do
    ctx = build_ctx(state)
    result = dispatch(state.extensions, event_type, payload, ctx)
    {:reply, result, state}
  end

  def handle_call({:emit_with_ctx, event_type, payload, extra_ctx}, _from, state) do
    ctx = Map.merge(build_ctx(state), extra_ctx)
    result = dispatch(state.extensions, event_type, payload, ctx)
    {:reply, result, state}
  end

  # ---------- dispatch helpers ----------

  defp dispatch(extensions, event_type, payload, ctx) do
    cond do
      event_type in @compound_events ->
        dispatch_compound(extensions, event_type, payload, ctx)

      event_type in @modifiable_events ->
        dispatch_modifiable(extensions, event_type, payload, ctx, %{})

      true ->
        dispatch_notification(extensions, event_type, payload, ctx)
    end
  end

  # Compound: stopped by the first non-:ok result (cancel OR modification).
  defp dispatch_compound([], _type, _payload, _ctx), do: :ok

  defp dispatch_compound([mod | rest], type, payload, ctx) do
    case call_extension(mod, type, payload, ctx) do
      {:cancel, reason} -> {:cancelled, reason}
      {:ok, mods} when is_map(mods) and map_size(mods) > 0 -> {:modified, mods}
      _ -> dispatch_compound(rest, type, payload, ctx)
    end
  end

  defp dispatch_modifiable([], _type, _payload, _ctx, acc) do
    if acc == %{}, do: :ok, else: {:modified, acc}
  end

  defp dispatch_modifiable([mod | rest], type, payload, ctx, acc) do
    new_acc =
      case call_extension(mod, type, payload, ctx) do
        {:ok, mods} when is_map(mods) -> Map.merge(acc, mods)
        _ -> acc
      end

    dispatch_modifiable(rest, type, payload, ctx, new_acc)
  end

  defp dispatch_notification(extensions, type, payload, ctx) do
    Enum.each(extensions, &call_extension(&1, type, payload, ctx))
    :ok
  end

  defp call_extension(mod, type, payload, ctx) do
    if function_exported?(mod, :on_event, 3) do
      mod.on_event(type, payload, ctx)
    else
      :ok
    end
  end

  defp build_ctx(state) do
    %{
      session_pid: state.session_pid,
      is_idle?: true,
      signal: nil
    }
  end
end
