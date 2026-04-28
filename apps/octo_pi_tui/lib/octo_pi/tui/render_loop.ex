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
      deadline = System.monotonic_time(:millisecond) + tick_ms
      loop(renderer, opts[:terminal], tick_ms, deadline, nil)
    end)
  end

  defp loop(renderer, terminal, tick_ms, deadline, pending) do
    wait = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {:render, lines, cursor_seq} ->
        loop(renderer, terminal, tick_ms, deadline, drain_latest(lines, cursor_seq))

      {:resize, w, h} ->
        loop(Renderer.resize(renderer, w, h), terminal, tick_ms, deadline, pending)

      :stop ->
        :ok
    after
      wait ->
        renderer =
          case pending do
            nil ->
              renderer

            {lines, cursor_seq} ->
              {bytes, r} = Renderer.render(renderer, lines, cursor_seq)
              if bytes != "", do: do_write(terminal, bytes)
              r
          end

        loop(renderer, terminal, tick_ms, deadline + tick_ms, nil)
    end
  end

  defp drain_latest(lines, cursor_seq) do
    receive do
      {:render, l, c} -> drain_latest(l, c)
    after
      0 -> {lines, cursor_seq}
    end
  end

  defp do_write(f, bytes) when is_function(f, 1), do: f.(bytes)
  defp do_write(pid, bytes) when is_pid(pid), do: Terminal.write(pid, bytes)
end
