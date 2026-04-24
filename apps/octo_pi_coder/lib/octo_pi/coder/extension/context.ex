defmodule OctoPi.Coder.Extension.Context do
  @moduledoc false

  @type t :: %__MODULE__{
          cwd: String.t(),
          model: term(),
          session_id: String.t() | nil,
          idle?: boolean(),
          signal: reference() | nil
        }

  defstruct cwd: ".",
            model: nil,
            session_id: nil,
            idle?: false,
            signal: nil

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
