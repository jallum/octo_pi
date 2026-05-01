defmodule OctoPi.TUI.Components.Loader do
  @moduledoc false

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

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

  def render(%__MODULE__{} = loader, width), do: render(loader, width, nil)

  @spec render(t(), pos_integer(), Theme.t() | nil) :: [String.t()]
  def render(%__MODULE__{frames: frames} = loader, width, theme) do
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
    ["", line]
  end

  def handle_key(%__MODULE__{cancellable: true} = loader, %Key{key: :escape}) do
    {loader, [:cancel]}
  end

  def handle_key(%__MODULE__{} = loader, %Key{}), do: loader
end
