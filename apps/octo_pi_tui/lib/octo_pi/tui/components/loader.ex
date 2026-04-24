defmodule OctoPi.TUI.Components.Loader do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.{Key, Theme}

  @default_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)

  defstruct message: "Loading...",
            frames: @default_frames,
            frame: 0,
            cancellable: false

  @type t :: %__MODULE__{
          message: String.t(),
          frames: [String.t()],
          frame: non_neg_integer(),
          cancellable: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      message: Keyword.get(opts, :message, "Loading..."),
      frames: Keyword.get(opts, :frames, @default_frames),
      frame: 0,
      cancellable: Keyword.get(opts, :cancellable, false)
    }
  end

  @spec advance_frame(t()) :: t()
  def advance_frame(%__MODULE__{frame: f, frames: frames} = loader) do
    %{loader | frame: rem(f + 1, length(frames))}
  end

  @spec set_message(t(), String.t()) :: t()
  def set_message(%__MODULE__{} = loader, message) do
    %{loader | message: message}
  end

  @impl true
  def render(%__MODULE__{} = loader, width), do: render(loader, width, nil)

  @spec render(t(), pos_integer(), Theme.t() | nil) :: [String.t()]
  def render(%__MODULE__{} = loader, width, theme) do
    spinner = Enum.at(loader.frames, loader.frame, "")

    line =
      case theme do
        %Theme{} ->
          Theme.fg(theme, :accent, spinner) <> " " <> Theme.fg(theme, :dim, loader.message)

        nil ->
          spinner <> " " <> loader.message
      end

    line = String.slice(line, 0, max(width, 0))
    cancel_lines = if loader.cancellable, do: ["", "  Press Esc to cancel"], else: []
    ["", line | cancel_lines]
  end

  @impl true
  def handle_key(%__MODULE__{cancellable: true} = loader, %Key{key: :escape}) do
    {loader, [:cancel]}
  end

  def handle_key(%__MODULE__{} = loader, %Key{}), do: loader
end
