defmodule OctoPi.TUI.RenderContext do
  @moduledoc """
  Render-time context threaded through every line-producing call.

  Theme and width are required — there is no such thing as a render
  with no theme. Callers that don't yet have one must not call
  `Component.render/2`.

  By construction this avoids the .14 trap of "ctx-baked-into-state":
  ctx is built fresh for each render pass and dropped at frame end;
  components store their own caches keyed against whatever fields they
  need from ctx (typically theme/width) and self-invalidate on
  mismatch.
  """

  @enforce_keys [:theme, :width]
  defstruct [
    :theme,
    :width,
    padding_x: 1,
    hide_thinking: false,
    hidden_thinking_label: "Thinking..."
  ]

  @type t :: %__MODULE__{
          theme: OctoPi.TUI.Theme.t(),
          width: pos_integer(),
          padding_x: non_neg_integer(),
          hide_thinking: boolean(),
          hidden_thinking_label: String.t()
        }
end
