defmodule OctoPi.Coder.Extension.Context do
  @moduledoc false

  @type t :: %__MODULE__{
          cwd: String.t(),
          model: term(),
          session_id: String.t() | nil,
          idle?: boolean(),
          signal: reference() | nil,
          has_ui?: boolean(),
          ui: OctoPi.Coder.Extension.UIContext.t() | nil
        }

  defstruct cwd: ".",
            model: nil,
            session_id: nil,
            idle?: false,
            signal: nil,
            has_ui?: false,
            ui: nil

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
