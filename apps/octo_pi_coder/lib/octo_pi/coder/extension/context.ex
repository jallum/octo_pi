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
          get_entries: (-> [Message.t()]),
          get_leaf_entry_id: (-> String.t() | nil)
        }

  defstruct cwd: ".",
            model: nil,
            session_id: nil,
            idle?: false,
            signal: nil,
            has_ui?: false,
            ui: nil,
            get_entries: &__MODULE__.empty_entries/0,
            get_leaf_entry_id: &__MODULE__.nil_entry_id/0

  @doc false
  @spec empty_entries() :: []
  def empty_entries, do: []

  @doc false
  @spec nil_entry_id() :: nil
  def nil_entry_id, do: nil

  @spec new(map()) :: t()
  def new(attrs), do: struct!(__MODULE__, attrs)
end
