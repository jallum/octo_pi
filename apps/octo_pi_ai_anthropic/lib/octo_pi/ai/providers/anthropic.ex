defmodule OctoPi.AI.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages provider. Implements `OctoPi.AI.Provider` by
  spawning an `OctoPi.AI.Providers.Anthropic.Producer` per call and
  draining its events into a lazy `Stream`.

  Phase 1 `stream_simple/3` is an alias for `stream/3` — reasoning
  level translation (adaptive/budget thinking, interleaved thinking
  beta) lands in a later phase per `docs/port-map/anthropic.md` §1.6.
  """

  @behaviour OctoPi.AI.Provider

  alias OctoPi.AI.Providers.Anthropic.Producer

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
        # Tests set `:req_overrides` in the app env to inject Req options
        # like `plug:` without exposing that knob on the public API.
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
