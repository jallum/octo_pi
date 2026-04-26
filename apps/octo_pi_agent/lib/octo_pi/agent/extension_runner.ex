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

  @cancellable_events ~w(session_before_compact session_before_fork session_before_tree tool_call input)a
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

  # ---------- GenServer callbacks ----------

  @impl true
  def init(opts) do
    {:ok, %{session_pid: Keyword.fetch!(opts, :session_pid), extensions: []}}
  end

  @impl true
  def handle_call({:register, module}, _from, state) do
    {:reply, :ok, %{state | extensions: state.extensions ++ [module]}}
  end

  def handle_call({:emit, event_type, payload}, _from, state) do
    ctx = build_ctx(state)
    result = dispatch(state.extensions, event_type, payload, ctx)
    {:reply, result, state}
  end

  # ---------- dispatch helpers ----------

  defp dispatch(extensions, event_type, payload, ctx) do
    cond do
      event_type in @cancellable_events ->
        dispatch_cancellable(extensions, event_type, payload, ctx)

      event_type in @modifiable_events ->
        dispatch_modifiable(extensions, event_type, payload, ctx, %{})

      true ->
        dispatch_notification(extensions, event_type, payload, ctx)
    end
  end

  defp dispatch_cancellable([], _type, _payload, _ctx), do: :ok

  defp dispatch_cancellable([mod | rest], type, payload, ctx) do
    case call_extension(mod, type, payload, ctx) do
      {:cancel, reason} -> {:cancelled, reason}
      _ -> dispatch_cancellable(rest, type, payload, ctx)
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
