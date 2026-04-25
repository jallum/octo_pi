defmodule OctoPi.Coder.Extension.Context do
  @moduledoc false

  alias OctoPi.Agent.Message

  @type t :: %__MODULE__{
          cwd: String.t(),
          model: term(),
          session_id: String.t() | nil,
          idle?: boolean(),
          signal: reference() | nil,
          has_ui?: boolean(),
          ui: OctoPi.Coder.Extension.UIContext.t() | nil,
          get_entries: (-> [Message.t()])
        }

  defstruct cwd: ".",
            model: nil,
            session_id: nil,
            idle?: false,
            signal: nil,
            has_ui?: false,
            ui: nil,
            get_entries: &__MODULE__.empty_entries/0

  @doc false
  @spec empty_entries() :: []
  def empty_entries, do: []

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
