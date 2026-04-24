defmodule OctoPi.Coder.Extension.Dispatcher do
  @moduledoc false

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.{Context, Event}

  require Logger

  @spec emit([Extension.t()], Event.t(), Context.t()) :: term()
  def emit(extensions, %{type: type} = event, ctx) do
    pattern = Event.pattern(type)
    handler_count = count_handlers(extensions, type)
    start = System.monotonic_time()

    result =
      case pattern do
        :fire_and_forget -> fire_and_forget(extensions, event, ctx)
        :cancel_on_result -> cancel_on_result(extensions, event, ctx)
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

  @spec cancel_on_result([Extension.t()], Event.t(), Context.t()) :: :ok | {:cancel, term()}
  def cancel_on_result(extensions, event, ctx) do
    Enum.reduce_while(all_handlers(extensions, event.type), :ok, fn {handler, ext}, :ok ->
      case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
        {:cancel, reason} ->
          emit_cancel_telemetry(ext, event.type, reason)
          {:halt, {:cancel, reason}}

        _ ->
          {:cont, :ok}
      end
    end)
  end

  @spec reduce_chain([Extension.t()], Event.event_type(), term(), Context.t()) :: term()
  def reduce_chain(extensions, event_type, acc, ctx) do
    Enum.reduce(all_handlers(extensions, event_type), acc, fn {handler, ext}, acc ->
      event = %{type: event_type, messages: acc}

      case safe_call(ext, event_type, fn -> handler.(event, ctx) end) do
        %{messages: new_msgs} -> new_msgs
        nil -> acc
        _ -> acc
      end
    end)
  end

  @spec mutate_in_place([Extension.t()], Event.t(), Context.t()) ::
          {:ok, Event.t()} | {:block, term()}
  def mutate_in_place(extensions, event, ctx) do
    Enum.reduce_while(all_handlers(extensions, event.type), {:ok, event}, fn {handler, ext}, {:ok, event} ->
      case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
        {:block, reason} ->
          emit_cancel_telemetry(ext, event.type, reason)
          {:halt, {:block, reason}}

        %{input: _} = updated ->
          {:cont, {:ok, updated}}

        _ ->
          {:cont, {:ok, event}}
      end
    end)
  end

  @spec patch_merge([Extension.t()], Event.t(), Context.t()) ::
          {:ok, map()} | :unchanged
  def patch_merge(extensions, event, ctx) do
    patches =
      Enum.reduce(all_handlers(extensions, event.type), %{}, fn {handler, ext}, merged ->
        case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
          %{} = patch when map_size(patch) > 0 -> Map.merge(merged, patch)
          _ -> merged
        end
      end)

    if map_size(patches) == 0, do: :unchanged, else: {:ok, patches}
  end

  @spec first_result([Extension.t()], Event.t(), Context.t()) :: term() | nil
  def first_result(extensions, event, ctx) do
    Enum.reduce_while(all_handlers(extensions, event.type), nil, fn {handler, ext}, nil ->
      case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
        nil -> {:cont, nil}
        result -> {:halt, result}
      end
    end)
  end

  @spec collect_all([Extension.t()], Event.t(), Context.t()) :: [term()]
  def collect_all(extensions, event, ctx) do
    all_handlers(extensions, event.type)
    |> Enum.reduce([], fn {handler, ext}, acc ->
      case safe_call(ext, event.type, fn -> handler.(event, ctx) end) do
        nil -> acc
        result -> [result | acc]
      end
    end)
    |> Enum.reverse()
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

  defp event_acc(%{messages: msgs}), do: msgs
  defp event_acc(%{payload: p}), do: p
  defp event_acc(event), do: event

  defp count_handlers(extensions, event_type) do
    Enum.sum(for ext <- extensions, do: length(Extension.get_handlers(ext, event_type)))
  end
end
