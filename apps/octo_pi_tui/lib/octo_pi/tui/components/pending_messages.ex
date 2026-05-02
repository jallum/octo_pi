defmodule OctoPi.TUI.Components.PendingMessages do
  @moduledoc false

  alias OctoPi.TUI.Components.Text
  alias OctoPi.TUI.Keybindings
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.WrapAnsi

  @spec render(
          %{
            pending_steering: [String.t()],
            pending_follow_up: [String.t()],
            keybindings: Keybindings.t()
          },
          RenderContext.t()
        ) :: VDOM.t()

  def render(%{pending_steering: [], pending_follow_up: []}, _ctx), do: %VDOM.VLines{lines: []}

  def render(%{pending_steering: steering, pending_follow_up: follow_up, keybindings: kb}, ctx) do
    steering_lines = Enum.map(steering, fn t -> %Text{content: Theme.dim("Steering: " <> t)} end)
    follow_up_lines = Enum.map(follow_up, fn t -> %Text{content: Theme.dim("Follow-up: " <> t)} end)

    hint_text =
      case Keybindings.get_keys(kb, "app.message.dequeue") do
        [key | _] -> Theme.dim("↳ #{key} to edit all queued messages")
        [] -> Theme.dim("↳ to edit all queued messages")
      end

    hint_line = %Text{content: hint_text}

    lines =
      (steering_lines ++ follow_up_lines ++ [hint_line])
      |> Enum.flat_map(&Text.render(&1, ctx.width))
      |> Enum.map(&fill_to_width(&1, ctx.width))

    %VDOM.VLines{lines: lines}
  end

  defp fill_to_width(line, width) do
    visible = WrapAnsi.visible_width(line)

    if visible < width do
      line <> String.duplicate(" ", width - visible)
    else
      line
    end
  end
end
