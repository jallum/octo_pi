defmodule OctoPi.TUI.Compat do
  @moduledoc """
  Adapter wrapping legacy Component.render/2 calls as %VLines{} leaves.

  The adapter bridges the old contract (Component.render(state, width) :: [binary()])
  and the transcript contract (Component.render(state, ctx) :: {state, lines, frame_ms})
  so existing components paint identically while migrations are in flight.

  Feature flag: :octo_pi_tui_vdom? — default false in config/config.exs.
  When false, Interactive continues calling components directly; when true,
  Interactive wraps legacy components via Compat.into_vlines/2 before passing
  to the reconciler.

  The wrapper computes visible width and memo-encodes the result so downstream
  VMemo works correctly. Per-ticket acceptance: a legacy Header paints identically
  wrapped vs. direct.
  """

  alias OctoPi.TUI.Component
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.WrapAnsi

  require Logger

  @enabled_key :octo_pi_tui_vdom?

  @doc "Return true if VDom mode is enabled."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:octo_pi_tui, @enabled_key, false)
  end

  @doc "Wrap a legacy component (old contract) as a %VLines leaf."
  @spec wrap_old_contract(module(), Component.t(), pos_integer()) :: VDOM.VLines.t()
  def wrap_old_contract(module, state, width) when is_atom(module) and is_integer(width) and width > 0 do
    # Call the old contract render function directly. If it crashes, let it bubble.
    lines = module.render(state, width)

    if !is_list(lines) do
      raise ArgumentError,
            "Compat.wrap_old_contract: expected [binary()] from #{module}.render/2, got #{inspect(lines)}"
    end

    ensure_string_lines(lines)
    %VDOM.VLines{lines: lines}
  end

  @doc "Wrap a legacy component (transcript contract) as a %VLines leaf."
  @spec wrap_transcript_contract(module(), Component.t(), RenderContext.t()) :: VDOM.VLines.t()
  def wrap_transcript_contract(module, state, ctx) do
    # Call the transcript contract: module.render(state, ctx) -> {state, [lines], frame_ms}
    case module.render(state, ctx) do
      {state2, lines, _frame_ms} when is_list(lines) ->
        ensure_string_lines(lines)
        {%VDOM.VLines{lines: lines}, state2}

      other ->
        raise ArgumentError,
              "Compat.wrap_transcript_contract: expected {state, [binary()], frame_ms} from #{module}.render/2, got #{inspect(other)}"
    end
  end

  @doc "Compute visible width of the first line for memo width metadata."
  @spec visible_width_of_vlines(VDOM.VLines.t()) :: non_neg_integer()
  def visible_width_of_vlines(%VDOM.VLines{lines: []}), do: 0
  def visible_width_of_vlines(%VDOM.VLines{lines: [first | _]}), do: WrapAnsi.visible_width(first)

  defp ensure_string_lines([]), do: []
  defp ensure_string_lines([first | _] = lines) when is_binary(first), do: lines

  defp ensure_string_lines(lines) do
    raise ArgumentError,
          "Compat: expected list of binaries, got #{inspect(lines)}"
  end
end
