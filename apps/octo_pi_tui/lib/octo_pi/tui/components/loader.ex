defmodule OctoPi.TUI.Components.Loader do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @default_frames ~w(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  @frame_interval_ms 80

  defstruct message: "Loading...",
            frames: @default_frames,
            cancellable: false

  @type t :: %__MODULE__{
          message: String.t(),
          frames: [String.t()],
          cancellable: boolean()
        }

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      message: Keyword.get(opts, :message, "Loading..."),
      frames: Keyword.get(opts, :frames, @default_frames),
      cancellable: Keyword.get(opts, :cancellable, false)
    }
  end

  @spec set_message(t(), String.t()) :: t()
  def set_message(%__MODULE__{} = loader, message) do
    %{loader | message: message}
  end

  @impl true
  def render(%__MODULE__{frames: frames} = loader, %RenderContext{theme: theme, width: width}) do
    frame = :millisecond |> System.monotonic_time() |> div(@frame_interval_ms) |> rem(length(frames))
    spinner = Enum.at(frames, frame, "")

    line =
      case theme do
        %Theme{} ->
          Theme.fg(theme, :accent, spinner) <> " " <> Theme.fg(theme, :dim, loader.message)

        nil ->
          spinner <> " " <> loader.message
      end

    line = String.slice(line, 0, max(width, 0))
    {loader, %VDOM.VLines{lines: ["", line]}}
  end

  @impl true
  def handle_key(%__MODULE__{cancellable: true} = loader, %Key{key: :escape}) do
    {loader, [:cancel]}
  end

  def handle_key(%__MODULE__{} = loader, %Key{}), do: loader
end
