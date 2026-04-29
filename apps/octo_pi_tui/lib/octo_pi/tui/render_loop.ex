defmodule OctoPi.TUI.RenderLoop do
  @moduledoc false

  alias OctoPi.TUI.Renderer
  alias OctoPi.TUI.Terminal

  @default_tick_ms 16

  @doc """
  Start a linked Task that owns the renderer and drives it on a fixed-interval
  monotonic clock.

  Options:
    * `:width` / `:height` — initial terminal dimensions (required)
    * `:terminal` — pid passed to `Terminal.write/2`, or a `(bytes -> any)`
      function used directly (useful for tests)
    * `:tick_ms` — tick interval in milliseconds (default #{@default_tick_ms})
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(opts) do
    Task.start_link(fn ->
      renderer =
        Renderer.new(
          width: opts[:width],
          height: opts[:height],
          csi_2026?: Keyword.get(opts, :csi_2026?, true)
        )

      tick_ms = Keyword.get(opts, :tick_ms, @default_tick_ms)
      loop(renderer, opts[:terminal], tick_ms, nil, 0)
    end)
  end

  defp loop(renderer, terminal, tick_ms, pending, frame) do
    wait =
      case pending do
        nil -> :infinity
        {deadline, _} -> max(0, deadline - System.monotonic_time(:millisecond))
      end

    receive do
      {:render, lines, cursor_seq} ->
        deadline = pending_deadline(pending, tick_ms)
        loop(renderer, terminal, tick_ms, {deadline, drain_latest(lines, cursor_seq)}, frame)

      {:resize, w, h} ->
        loop(Renderer.resize(renderer, w, h), terminal, tick_ms, pending, frame)

      :stop ->
        :ok
    after
      wait ->
        {_deadline, {lines, cursor_seq}} = pending
        start_mono = System.monotonic_time()
        {bytes, new_renderer} = Renderer.render(renderer, lines, cursor_seq)

        emit_render_telemetry(
          renderer,
          new_renderer,
          lines,
          System.monotonic_time() - start_mono,
          byte_size(bytes),
          frame
        )

        if bytes != "", do: do_write(terminal, bytes)
        loop(new_renderer, terminal, tick_ms, nil, frame + 1)
    end
  end

  defp pending_deadline(nil, tick_ms), do: System.monotonic_time(:millisecond) + tick_ms
  defp pending_deadline({deadline, _}, _tick_ms), do: deadline

  defp drain_latest(lines, cursor_seq) do
    receive do
      {:render, l, c} -> drain_latest(l, c)
    after
      0 -> {lines, cursor_seq}
    end
  end

  defp emit_render_telemetry(old_r, new_r, lines, duration, byte_count, frame) do
    {mode, lines_changed} = render_mode(old_r, new_r, lines)

    :telemetry.execute(
      [:octo_pi_tui, :renderer, :render],
      %{duration: duration, byte_count: byte_count, lines_changed: lines_changed},
      %{mode: mode, line_count: length(lines), frame: frame}
    )
  end

  defp render_mode(%{previous: nil}, _new_r, lines), do: {:first, length(lines)}
  defp render_mode(%{full_redraws: n}, %{full_redraws: m}, lines) when m > n, do: {:full, length(lines)}

  defp render_mode(old_r, _new_r, lines) do
    case Renderer.find_diff_range(lines, old_r.previous) do
      {-1, _} -> {:noop, 0}
      {first, last} -> {:diff, last - first + 1}
    end
  end

  defp do_write(f, bytes) when is_function(f, 1), do: f.(bytes)
  defp do_write(pid, bytes) when is_pid(pid), do: Terminal.write(pid, bytes)
end
