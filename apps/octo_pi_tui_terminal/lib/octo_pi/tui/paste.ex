defmodule OctoPi.TUI.Paste do
  @moduledoc """
  A paste event from a human input device.

  `:content` carries the raw bytes. `:filename` and `:content_type`
  are populated when the source provides them (e.g. a future image-
  paste path); bracketed-paste from the terminal leaves them `nil`.
  """

  @enforce_keys [:content]
  defstruct [:content, :filename, :content_type]

  @type t :: %__MODULE__{
          content: binary(),
          filename: String.t() | nil,
          content_type: String.t() | nil
        }
end
