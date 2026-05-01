defmodule OctoPi.TUI.RenderTelemetry do
  @moduledoc """
  Helpers that emit the render-path telemetry events registered in
  `OctoPi.TUI.Application` under `:tui_render` and `:tui_interactive`.

  Events emitted:

    * `[:octo_pi_tui, :interactive, :handle_info, :start | :stop]` — span
      around each `Interactive.handle_info/2` clause, with `kind` metadata
      identifying the message family.
    * `[:octo_pi_tui, :interactive, :mailbox]` — execute on `handle_info`
      entry; measurements `%{message_queue_len: n}`.
    * `[:octo_pi_tui, :key, :latency]` — fires when a `{:hid_event, _, mono}`
      3-tuple arrives; measurements `%{duration_us: arrival_to_handle}`.
    * `[:octo_pi_tui, :transcript, :render, :start | :stop]` — span around
      `render_transcript`.
    * `[:octo_pi_tui, :markdown, :render, :start | :stop]` — span around
      a single `Markdown.render` call.

  Hot-path: every public function here runs on every keystroke / stream
  chunk / render. Keep them tight.
  """

  @type handle_info_kind ::
          :hid_event | :octo_pi_agent_event | :timeout | :extension_result | :force_render | :other

  @doc """
  Wrap an `Interactive.handle_info/2` body. Emits the `handle_info` span,
  the mailbox sample, and `key.latency` (when applicable) before calling
  `fun.()`. Returns the function's value.
  """
  @spec with_handle_info(term(), (-> result)) :: result when result: var
  def with_handle_info(msg, fun) when is_function(fun, 0) do
    kind = classify(msg)
    queue_len = mailbox_len()

    :telemetry.execute(
      [:octo_pi_tui, :interactive, :mailbox],
      %{message_queue_len: queue_len},
      %{at: :handle_info_entry}
    )

    maybe_emit_key_latency(msg, queue_len)

    :telemetry.span(
      [:octo_pi_tui, :interactive, :handle_info],
      %{kind: kind, mailbox_len_before: queue_len},
      fn ->
        result = fun.()
        {result, %{kind: kind}}
      end
    )
  end

  @doc """
  Wrap a `render_transcript` call. `meta` should include `:msg_count` and
  `:streaming?`; `line_count` is added on stop.
  """
  @spec with_transcript_render(map(), (-> [iolist])) :: [iolist]
  def with_transcript_render(meta, fun) when is_map(meta) and is_function(fun, 0) do
    :telemetry.span(
      [:octo_pi_tui, :transcript, :render],
      meta,
      fn ->
        lines = fun.()
        {lines, Map.put(meta, :line_count, length(lines))}
      end
    )
  end

  defp classify({:hid_event, _, _}), do: :hid_event
  defp classify({:hid_event, _}), do: :hid_event
  defp classify({:octo_pi_agent_event, _}), do: :octo_pi_agent_event
  defp classify(:timeout), do: :timeout
  defp classify(:force_render), do: :force_render
  defp classify({:extension_result, _}), do: :extension_result
  defp classify({:bash_done, _, _, _}), do: :bash_done
  defp classify({:custom_done, _, _}), do: :custom_done
  defp classify({:EXIT, _, _}), do: :exit
  defp classify(_), do: :other

  defp mailbox_len do
    case Process.info(self(), :message_queue_len) do
      {:message_queue_len, n} -> n
      _ -> 0
    end
  end

  defp maybe_emit_key_latency({:hid_event, _, arrival_us}, queue_len) when is_integer(arrival_us) do
    duration_us = max(0, System.monotonic_time(:microsecond) - arrival_us)

    :telemetry.execute(
      [:octo_pi_tui, :key, :latency],
      %{duration_us: duration_us},
      %{mailbox_len_at_arrival: queue_len}
    )
  end

  defp maybe_emit_key_latency(_msg, _queue_len), do: :ok
end
