defmodule OctoPi.AI.Providers.OpenAI do
  @moduledoc """
  OpenAI Completions provider. Implements `OctoPi.AI.Provider` by
  spawning an `OctoPi.AI.Providers.OpenAI.Producer` per call and
  draining its events into a lazy `Stream`.

  Covers OpenAI proper and any provider speaking the same chat
  completions dialect (xAI, DeepSeek, OpenRouter, etc.) — the
  `Compat` layer handles per-provider quirks.
  """

  @behaviour OctoPi.AI.Provider

  alias OctoPi.AI.Providers.OpenAI.Producer

  @impl true
  def stream(model, context, opts) do
    caller = self()
    ref = make_ref()

    {:ok, pid} =
      Producer.start(%{
        model: model,
        context: context,
        opts: opts,
        caller: caller,
        ref: ref,
        req_overrides: Application.get_env(:octo_pi_ai, :req_overrides, [])
      })

    build_stream(pid, ref)
  end

  @impl true
  def stream_simple(model, context, opts), do: stream(model, context, opts)

  defp build_stream(pid, ref) do
    Stream.resource(
      fn ->
        mon = Process.monitor(pid)
        {pid, ref, mon}
      end,
      &next/1,
      &cleanup/1
    )
  end

  defp next({_pid, ref, mon} = acc) do
    receive do
      {^ref, :event, event} ->
        {[event], acc}

      {^ref, :done} ->
        {:halt, acc}

      {:DOWN, ^mon, :process, _, _reason} ->
        {:halt, acc}
    end
  end

  defp cleanup({pid, _ref, mon}) do
    Process.demonitor(mon, [:flush])
    if Process.alive?(pid), do: Process.exit(pid, :shutdown)
    :ok
  end
end
