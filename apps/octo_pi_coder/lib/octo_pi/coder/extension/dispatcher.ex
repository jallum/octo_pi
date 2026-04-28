defmodule OctoPi.Coder.Extension.Dispatcher do
  @moduledoc false

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event

  require Logger

  @doc """
  Emit an `:input` event using transform/handled/continue chaining.

  Each handler receives the current input state `%{type: :input, text:,
  images:, source:, action:}`. Return values:

    * `%{action: :transform, text:, images?: ...}` — updates text and
      optionally images; the updated state is passed to the next handler.
    * `%{action: :handled}` — short-circuits; no further handlers run.
    * Anything else (`:continue`, `nil`, raise) — state is unchanged.

  Returns the final state map.
  """
  @spec emit_input([Extension.t()], String.t(), [map()] | nil, atom(), Context.t()) :: map()
  def emit_input(extensions, text, images, source, ctx) do
    initial = %{type: :input, text: text, images: images, source: source, action: :continue}

    Enum.reduce_while(all_handlers(extensions, :input), initial, fn {handler, ext}, state ->
      result = safe_call(ext, :input, fn -> handler.(state, ctx) end)
      apply_input_result(result, state)
    end)
  end

  @spec emit([Extension.t()], Event.t(), Context.t()) :: term()
  def emit(extensions, %{type: :input, text: text, images: images, source: source}, ctx) do
    emit_input(extensions, text, images, source, ctx)
  end

  def emit(extensions, %{type: type} = event, ctx) do
    pattern = Event.pattern(type)
    handler_count = count_handlers(extensions, type)
    start = System.monotonic_time()

    result =
      case pattern do
        :fire_and_forget -> fire_and_forget(extensions, event, ctx)
        :halt_on_result -> halt_on_result(extensions, event, ctx)
        :reduce_chain -> reduce_chain(extensions, type, event_acc(event), ctx)
        :mutate_in_place -> mutate_in_place(extensions, event, ctx)
        :patch_merge -> patch_merge(extensions, event, ctx)
        :first_result -> first_result(extensions, event, ctx)
        :collect_all -> collect_all(extensions, event, ctx)
      end

    duration = System.monotonic_time() - start

    :telemetry.execute(
      [:octo_pi_coder, :extension, :emit],
      %{duration: duration},
      %{event_type: type, pattern: pattern, handler_count: handler_count}
    )

    result
  end

  @spec fire_and_forget([Extension.t()], Event.t(), Context.t()) :: :ok
  def fire_and_forget(extensions, event, ctx) do
    each_handler(extensions, event.type, fn handler, ext ->
      safe_call(ext, event.type, fn -> handler.(event, ctx) end)
    end)

    :ok
  end

  @doc """
  Run handlers in order until one returns a halting result.

  Halting return shapes:
    * `{:cancel, reason}` — abort the operation; reason is surfaced to caller.
    * `{:override, value}` — extension supplies a result that replaces the
      default operation. The value is opaque to the dispatcher.

  Anything else (`:ok`, `nil`, raise, other) → continue to the next handler.

  Renamed from `cancel_on_result/3` (which only had the cancel channel) so
  extensions like `:session_before_compact` can supply pre-built results
  without smuggling them through the cancel channel.
  """
  @spec halt_on_result([Extension.t()], Event.t(), Context.t()) ::
          :ok | {:cancel, term()} | {:override, term()}
  def halt_on_result(extensions, event, ctx) do
    Enum.reduce_while(all_handlers(extensions, event.type), :ok, fn {handler, ext}, :ok ->
      try_halt(ext, event, ctx, handler)
    end)
  end

  @spec reduce_chain([Extension.t()], Event.event_type(), term(), Context.t()) :: term()
  def reduce_chain(extensions, event_type, acc, ctx) do
    Enum.reduce(all_handlers(extensions, event_type), acc, fn {handler, ext}, acc ->
      reduce_chain_step(ext, event_type, acc, ctx, handler)
    end)
  end

  @spec mutate_in_place([Extension.t()], Event.t(), Context.t()) ::
          {:ok, Event.t()} | {:block, term()}
  def mutate_in_place(extensions, event, ctx) do
    Enum.reduce_while(all_handlers(extensions, event.type), {:ok, event}, fn {handler, ext}, {:ok, event} ->
      try_mutate(ext, event, ctx, handler)
    end)
  end

  @spec patch_merge([Extension.t()], Event.t(), Context.t()) ::
          {:ok, map()} | :unchanged
  def patch_merge(extensions, event, ctx) do
    patches =
      Enum.reduce(all_handlers(extensions, event.type), %{}, fn {handler, ext}, merged ->
        merge_patch(ext, event, ctx, handler, merged)
      end)

    if map_size(patches) == 0, do: :unchanged, else: {:ok, patches}
  end

  @spec first_result([Extension.t()], Event.t(), Context.t()) :: term() | nil
  def first_result(extensions, event, ctx) do
    Enum.reduce_while(all_handlers(extensions, event.type), nil, fn {handler, ext}, nil ->
      try_first(ext, event, ctx, handler)
    end)
  end

  @spec collect_all([Extension.t()], Event.t(), Context.t()) :: [term()]
  def collect_all(extensions, event, ctx) do
    extensions
    |> all_handlers(event.type)
    |> Enum.reduce([], fn {handler, ext}, acc ->
      collect_step(ext, event, ctx, handler, acc)
    end)
    |> Enum.reverse()
  end

  # --- introspection ---

  @spec get_extension_paths([Extension.t()]) :: [String.t()]
  def get_extension_paths(extensions), do: Enum.map(extensions, & &1.path)

  @spec get_all_tools([Extension.t()]) :: [map()]
  def get_all_tools(extensions) do
    extensions
    |> Enum.flat_map(fn ext -> Map.values(ext.tools) end)
    |> Enum.uniq_by(& &1.name)
  end

  @spec get_tool_definition([Extension.t()], String.t()) :: map() | nil
  def get_tool_definition(extensions, name) do
    Enum.find_value(extensions, fn ext -> Map.get(ext.tools, name) end)
  end

  @spec get_all_commands([Extension.t()]) :: [{String.t(), map(), String.t()}]
  def get_all_commands(extensions) do
    {cmds, _} =
      Enum.reduce(extensions, {[], MapSet.new()}, fn ext, {acc, seen} ->
        Enum.reduce(ext.commands, {acc, seen}, fn {name, cmd}, {acc, seen} ->
          dedup_command(name, cmd, ext.id, acc, seen)
        end)
      end)

    Enum.reverse(cmds)
  end

  @spec get_command([Extension.t()], String.t()) :: {map(), String.t()} | nil
  def get_command(extensions, name) do
    Enum.find_value(extensions, fn ext ->
      case Map.get(ext.commands, name) do
        nil -> nil
        cmd -> {cmd, ext.id}
      end
    end)
  end

  @spec get_message_renderer([Extension.t()], String.t()) :: Extension.message_renderer() | nil
  def get_message_renderer(extensions, type) do
    Enum.find_value(extensions, fn ext -> Map.get(ext.message_renderers, type) end)
  end

  @spec has_handlers?([Extension.t()], Event.event_type()) :: boolean()
  def has_handlers?(extensions, event_type) do
    Enum.any?(extensions, fn ext -> Extension.get_handlers(ext, event_type) != [] end)
  end

  @spec get_command_diagnostics([Extension.t()]) :: [
          %{name: String.t(), extensions: [String.t()]}
        ]
  def get_command_diagnostics(extensions) do
    extensions
    |> Enum.flat_map(fn ext -> Enum.map(ext.commands, fn {name, _} -> {name, ext.id} end) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_name, ext_ids} -> length(ext_ids) > 1 end)
    |> Enum.map(fn {name, ext_ids} -> %{name: name, extensions: ext_ids} end)
  end

  @type command_entry :: %{
          name: String.t(),
          invocation_name: String.t(),
          cmd: Extension.command_spec(),
          ext_id: String.t()
        }

  @doc """
  Returns all commands from all extensions with `invocation_name` set.
  Unique commands get `invocation_name == name`. Duplicate names across
  extensions get `:1`, `:2` suffixes in insertion order — matching
  upstream pi-mono's runner `getRegisteredCommands()` semantics.
  """
  @spec get_registered_commands([Extension.t()]) :: [command_entry()]
  def get_registered_commands(extensions) do
    all =
      Enum.flat_map(extensions, fn ext ->
        Enum.map(ext.commands, fn {name, cmd} -> {name, cmd, ext.id} end)
      end)

    name_counts = Enum.frequencies_by(all, &elem(&1, 0))

    {result, _} =
      Enum.map_reduce(all, %{}, fn {name, cmd, ext_id}, counters ->
        if Map.fetch!(name_counts, name) > 1 do
          idx = Map.get(counters, name, 0) + 1
          entry = %{name: name, invocation_name: "#{name}:#{idx}", cmd: cmd, ext_id: ext_id}
          {entry, Map.put(counters, name, idx)}
        else
          {%{name: name, invocation_name: name, cmd: cmd, ext_id: ext_id}, counters}
        end
      end)

    result
  end

  @doc "Look up a command by its `invocation_name`."
  @spec get_command_by_invocation([Extension.t()], String.t()) ::
          {Extension.command_spec(), String.t()} | nil
  def get_command_by_invocation(extensions, invocation_name) do
    case Enum.find(get_registered_commands(extensions), &(&1.invocation_name == invocation_name)) do
      nil -> nil
      entry -> {entry.cmd, entry.ext_id}
    end
  end

  @doc "Collect all flags from all extensions (first-wins deduplication by name)."
  @spec get_all_flags([Extension.t()]) :: [{String.t(), Extension.flag_spec()}]
  def get_all_flags(extensions) do
    extensions
    |> Enum.flat_map(fn ext -> Enum.to_list(ext.flags) end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  @doc "Collect all shortcuts from all extensions (insertion order, no conflict detection)."
  @spec get_all_shortcuts([Extension.t()]) :: [{String.t(), Extension.shortcut_spec()}]
  def get_all_shortcuts(extensions) do
    Enum.flat_map(extensions, fn ext -> Enum.to_list(ext.shortcuts) end)
  end

  # --- dispatch step helpers ---

  defp apply_input_result(%{action: :handled} = result, _state), do: {:halt, result}

  defp apply_input_result(%{action: :transform} = result, state) do
    new_state = %{state | text: result.text, images: Map.get(result, :images, state.images), action: :transform}
    {:cont, new_state}
  end

  defp apply_input_result(_, state), do: {:cont, %{state | action: :continue}}

  defp try_halt(ext, event, ctx, handler) do
    case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
      {:cancel, reason} ->
        emit_cancel_telemetry(ext, event.type, reason)
        {:halt, {:cancel, reason}}

      {:override, value} ->
        emit_override_telemetry(ext, event.type)
        {:halt, {:override, value}}

      _ ->
        {:cont, :ok}
    end
  end

  defp reduce_chain_step(ext, event_type, acc, ctx, handler) do
    event = %{type: event_type, messages: acc}

    case safe_call(ext, event_type, fn -> handler.(event, ctx) end) do
      %{messages: new_msgs} -> new_msgs
      _ -> acc
    end
  end

  defp try_mutate(ext, event, ctx, handler) do
    case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
      {:block, reason} ->
        emit_cancel_telemetry(ext, event.type, reason)
        {:halt, {:block, reason}}

      %{input: _} = updated ->
        {:cont, {:ok, updated}}

      _ ->
        {:cont, {:ok, event}}
    end
  end

  defp merge_patch(ext, event, ctx, handler, merged) do
    case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
      %{} = patch when map_size(patch) > 0 -> Map.merge(merged, patch)
      _ -> merged
    end
  end

  defp try_first(ext, event, ctx, handler) do
    case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
      nil -> {:cont, nil}
      result -> {:halt, result}
    end
  end

  defp collect_step(ext, event, ctx, handler, acc) do
    case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
      nil -> acc
      result -> [result | acc]
    end
  end

  defp dedup_command(name, cmd, ext_id, acc, seen) do
    if MapSet.member?(seen, name) do
      {acc, seen}
    else
      {[{name, cmd, ext_id} | acc], MapSet.put(seen, name)}
    end
  end

  # --- internal ---

  defp all_handlers(extensions, event_type) do
    for ext <- extensions,
        handler <- Extension.get_handlers(ext, event_type),
        do: {handler, ext}
  end

  defp each_handler(extensions, event_type, fun) do
    for ext <- extensions,
        handler <- Extension.get_handlers(ext, event_type) do
      fun.(handler, ext)
    end
  end

  defp safe_call(ext, event_type, fun) do
    fun.()
  rescue
    e ->
      :telemetry.execute(
        [:octo_pi_coder, :extension, :handler_error],
        %{},
        %{
          extension_id: ext.id,
          event_type: event_type,
          error: Exception.message(e),
          stacktrace: __STACKTRACE__
        }
      )

      Logger.warning("Extension #{ext.id} handler error on #{event_type}: #{Exception.message(e)}")

      nil
  end

  defp emit_cancel_telemetry(ext, event_type, reason) do
    :telemetry.execute(
      [:octo_pi_coder, :extension, :handler_cancel],
      %{},
      %{extension_id: ext.id, event_type: event_type, reason: reason}
    )
  end

  defp emit_override_telemetry(ext, event_type) do
    :telemetry.execute(
      [:octo_pi_coder, :extension, :handler_override],
      %{},
      %{extension_id: ext.id, event_type: event_type}
    )
  end

  defp event_acc(%{messages: msgs}), do: msgs
  defp event_acc(%{payload: p}), do: p
  defp event_acc(event), do: event

  defp count_handlers(extensions, event_type) do
    Enum.sum(for ext <- extensions, do: length(Extension.get_handlers(ext, event_type)))
  end
end
